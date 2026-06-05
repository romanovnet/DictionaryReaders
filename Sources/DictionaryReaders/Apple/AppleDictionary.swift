// SPDX-License-Identifier: MIT
import Foundation

/// Immutable keyword catalog with demand-loaded article sections. The shared
/// cache owns its synchronization; dictionary values hold no mutable parsing state.
public struct AppleDictionary: DictionarySource, BodyIndexable, DictionaryResourceProvider, Sendable {
    public let bundleURL: URL
    public let name: String
    public let css: String?
    public let resourcesDirectory: URL
    public let languagePair: LanguagePair?
    public let embeddedIconData: Data?
    private let bodyFile: Data
    private let compressed: Bool
    private let cache = LRUCache<Int, Data>(capacity: 24)
    private enum Article: Sendable {
        case section(Int, Int)
        case flat(Int)
        case rendered(String)
    }
    private let articles: [Article]
    private let words: [[String]]
    private let matches: [String: [Int]]
    private let sorted: [String]

    public init(bundleURL: URL) async throws {
        self.bundleURL = bundleURL
        let fm = FileManager.default
        let contents: URL
        if bundleURL.lastPathComponent == "Contents" { contents = bundleURL }
        else if bundleURL.lastPathComponent == "Body.data" {
            let parent = bundleURL.deletingLastPathComponent()
            contents = parent.lastPathComponent == "Resources" ? parent.deletingLastPathComponent() : parent
        } else { contents = bundleURL.appendingPathComponent("Contents") }
        guard let info = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any] else {
            throw AppleDictionaryError.notAppleDictionary(bundleURL)
        }
        let candidates = [contents.appendingPathComponent("Resources"), contents]
        guard let resources = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("Body.data").path) }) else {
            throw AppleDictionaryError.missingBodyData(bundleURL)
        }
        resourcesDirectory = resources
        let url = resources.appendingPathComponent("Body.data")
        guard let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw AppleDictionaryError.fileNotReadable(url) }
        bodyFile = file
        name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? contents.deletingLastPathComponent().deletingPathExtension().lastPathComponent
        let cssName = plist["DCSDictionaryCSS"] as? String ?? "DefaultStyle.css"
        css = Self.safeFile(cssName, under: resources).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        embeddedIconData = Self.readBundleIcon(contents: contents, plist: plist)
        let languages = (plist["DCSDictionaryLanguages"] as? [[String: Any]] ?? []).compactMap { $0["DCSDictionaryIndexLanguage"] as? String }
        languagePair = languages.first.map { LanguagePair(source: $0, target: languages.last ?? $0) }
        let indexes = plist["IDXDictionaryIndexes"] as? [[String: Any]] ?? []
        let body = indexes.first { ($0["IDXIndexName"] as? String) == "DCSBodyDataIndex" || ($0["IDXIndexPath"] as? String) == "Body.data" } ?? [:]
        compressed = (body["HeapDataCompressionType"] as? Int ?? 0) > 0
        let keywords = indexes.first { ($0["IDXIndexName"] as? String) == "DCSKeywordIndex" } ?? [:]
        let auxiliary = keywords["TrieAuxiliaryDataOptions"] as? [String: Any] ?? [:]
        let fields = keywords["IDXIndexDataFields"] as? [String: Any] ?? [:]
        let fixed = fields["IDXFixedDataFields"] as? [[String: Any]] ?? []
        let external = fields["IDXExternalDataFields"] as? [[String: Any]] ?? []
        let sections = external.first?["IDXDataSize"] as? Int == 8
        var fixedSize = 0
        for field in fixed {
            let size = field["IDXDataSize"] as? Int ?? 0
            let sum = fixedSize.addingReportingOverflow(size)
            guard size >= 0, !sum.overflow else { throw AppleDictionaryError.notAppleDictionary(bundleURL) }
            fixedSize = sum.partialValue
        }
        let props = AppleProps(keyTextCompressed: (auxiliary["HeapDataCompressionType"] as? Int ?? 0) > 0,
                               bodyHasSections: sections,
                               fixedFieldByteLen: fixedSize)
        var locations: [Article] = [], labels: [[String]] = []
        if let catalog = AppleKeyText.index(at: resources.appendingPathComponent("KeyText.data"), props: props) {
            labels = catalog.keywordsByAddress
            locations = catalog.addresses.map { sections ? .section($0.sectionOffset, $0.chunkOffset) : .flat($0.chunkOffset) }
        } else if let span = AppleHeap.range(file) {
            // A missing/corrupt native index still permits canonical-title lookup.
            var block = span.lowerBound
            let expression = try! NSRegularExpression(pattern: #"(?s)<d:entry\b[^>]*>.*?</d:entry>"#)
            while block < span.upperBound {
                guard let jump = AppleHeap.integer(file, 64 + block), jump > 0, jump <= span.upperBound - block else { break }
                if let payload = AppleHeap.bodySection(file, address: block, compressed: compressed) {
                    // Length prefixes are arbitrary bytes, so decode UTF-8 with replacement.
                    let text = String(decoding: payload, as: UTF8.self)
                    let ns = text as NSString
                    for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        let entry = ns.substring(with: match.range)
                        guard let end = entry.firstIndex(of: ">"), let label = XmlText.attribute(String(entry[...end]), "d:title") else { continue }
                        labels.append([XmlText.decodeEntities(label)]); locations.append(.rendered(Self.entryToHTML(entry)))
                    }
                }
                block += jump + 4
            }
        }
        guard !locations.isEmpty else { throw AppleDictionaryError.noEntries(bundleURL) }
        var index: [String: [Int]] = [:]
        for (ordinal, names) in labels.enumerated() {
            for key in Set(names.map(LookupKey.fold)) { index[key, default: []].append(ordinal) }
        }
        words = labels; articles = locations; matches = index; sorted = index.keys.sorted()
    }
    private static func safeFile(_ name: String, under root: URL) -> URL? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(base.path + "/") ? file : nil
    }
    static func readBundleIcon(contents: URL, plist: [String: Any]) -> Data? {
        let declared = [plist["CFBundleIconFile"], plist["CFBundleIconName"]]
            .compactMap { $0 as? String }.filter { !$0.isEmpty }
        let names = declared.flatMap { name in
            (name as NSString).pathExtension.isEmpty
                ? [name] + ["icns", "png", "tiff", "jpg", "jpeg", "bmp", "gif"].map { name + "." + $0 }
                : [name]
        }
        for root in [contents.appendingPathComponent("Resources"), contents] {
            for candidate in names {
                if let url = safeFile(candidate, under: root), let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }
    static func entryToHTML(_ entry: String) -> String {
        let inner = entry.replacingOccurrences(of: #"</?d:[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+xmlns(?::[\w-]+)?\s*=\s*(?:"[^"]*"|'[^']*')"#, with: "", options: .regularExpression)
        return "<div class=\"apple_entry\">\(inner)</div>"
    }
    private func html(_ ordinal: Int) -> String? {
        let data: Data, offset: Int
        switch articles[ordinal] {
        case .rendered(let text): return text
        case .flat(let position): data = bodyFile; offset = position + 64
        case .section(let section, let position):
            if let cached = cache.value(for: section) { data = cached }
            else {
                guard let decoded = AppleHeap.bodySection(bodyFile, address: section, compressed: compressed) else { return nil }
                cache.insert(decoded, for: section); data = decoded
            }
            offset = position
        }
        guard offset >= 0, offset < data.count else { return nil }
        // The address denotes a length-prefixed XML record, not the XML itself.
        let marker = Data("<d:entry".utf8)
        let window = offset..<min(offset + 20, data.count)
        guard let start = data.range(of: marker, in: window)?.lowerBound,
              let closing = data.range(of: Data("</d:entry>".utf8), in: start..<data.count) else { return nil }
        return Self.entryToHTML(String(decoding: data[start..<closing.upperBound], as: UTF8.self))
    }
    public var format: DictionaryFormat { .appleDictionary }
    public var title: String { name }
    public var headwordCount: Int { matches.count }
    public func lookup(exact headword: String) -> [DictionaryEntry] {
        (matches[LookupKey.fold(headword)] ?? []).compactMap { ordinal in
            html(ordinal).map { DictionaryEntry(headwords: words[ordinal], markup: .html($0), sourceFormat: format, sourceTitle: title) }
        }
    }
    public func prefix(matching prefix: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let key = LookupKey.fold(prefix)
        return Array(sorted.lazy.filter { $0.hasPrefix(key) }.prefix(limit))
    }
    public func allHeadwords() -> [String] { sorted }
    public func resource(forPath path: String) -> (data: Data, mimeType: String)? {
        guard let url = Self.safeFile(path.removingPercentEncoding ?? path, under: resourcesDirectory), let data = try? Data(contentsOf: url) else { return nil }
        return (data, ResourceMIME.type(forPath: path))
    }
    public var indexEntries: [IndexableEntry] {
        articles.indices.compactMap { ordinal in html(ordinal).map { IndexableEntry(headwords: words[ordinal], body: $0) } }
    }
    public var indexTitle: String { title }
    public var indexSourceURL: URL { bundleURL }
    public var indexCSS: String? { css }
}
public enum AppleDictionaryError: Error, Equatable {
    case notAppleDictionary(URL), missingBodyData(URL), fileNotReadable(URL), noEntries(URL)
}
