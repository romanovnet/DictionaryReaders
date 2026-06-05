// SPDX-License-Identifier: MIT
import Foundation

/// BGL adapter built around immutable decoded records and a folded lookup index.
public struct BabylonDictionary: DictionarySource, BodyIndexable, Sendable {
    public let sourceURL: URL
    public let name: String
    private let records: [IndexableEntry]
    private let matches: [String: [Int]]
    private let keys: [String]

    public init(url: URL) async throws {
        let blocks = try BglFile(url: url).blocks
        var metadata: [Int: Data] = [:]
        var fallback: UInt8 = 0x42
        for block in blocks {
            var cursor = ReaderBytes(block.data)
            if block.type == 3, let code = cursor.number(2) { metadata[code] = cursor.take(cursor.remaining) }
            if block.type == 0, cursor.number(1) == 8, let code = cursor.number(1) { fallback = UInt8(code) }
        }
        let flags = metadata[0x11]?.reduce(0) { ($0 << 8) | Int($1) } ?? 0
        let utf8 = flags & 0x8000 != 0
        let source = utf8 ? String.Encoding.utf8 : BglCharset.encoding(forCharsetCode: metadata[0x1a]?.first ?? fallback)
        let target = utf8 ? String.Encoding.utf8 : BglCharset.encoding(forCharsetCode: metadata[0x1b]?.first ?? fallback)
        let title = metadata[1].map { BglText.decode(Array($0), target).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        name = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        sourceURL = url
        var entries: [IndexableEntry] = [], index: [String: [Int]] = [:]
        entryLoop: for block in blocks where [1, 7, 10, 11, 13].contains(block.type) {
            var row = ReaderBytes(block.data)
            let wide = block.type == 11
            guard let primary = row.field(wide ? 5 : 1) else { continue }
            var words = [primary]
            var definition: Data?
            if wide {
                guard let count = row.number(4) else { continue }
                for _ in 0..<count {
                    guard let word = row.field(4) else { continue entryLoop }
                    if word.isEmpty { break }
                    words.append(word)
                }
                definition = row.field(4)
            } else {
                definition = row.field(2)
                while let alternate = row.field(1) { words.append(alternate) }
            }
            guard let definition else { continue }
            var seen = Set<String>()
            let headwords = words.map { BglText.processKey(Array($0), sourceEncoding: source) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !headwords.isEmpty else { continue }
            let ordinal = entries.count
            entries.append(IndexableEntry(headwords: headwords, body: BglText.processDefi(Array(definition), sourceEncoding: source, targetEncoding: target)))
            for key in Set(headwords.map(LookupKey.fold)) { index[key, default: []].append(ordinal) }
        }
        guard !entries.isEmpty else { throw BabylonError.noEntries(url) }
        records = entries; matches = index; keys = index.keys.sorted()
    }
    public var format: DictionaryFormat { .babylon }
    public var title: String { name }
    public var languagePair: LanguagePair? { nil }
    public var headwordCount: Int { matches.count }
    public func lookup(exact headword: String) -> [DictionaryEntry] {
        (matches[LookupKey.fold(headword)] ?? []).map {
            DictionaryEntry(headwords: records[$0].headwords, markup: .html(records[$0].body), sourceFormat: format, sourceTitle: title)
        }
    }
    public func allHeadwords() -> [String] { keys }
    public func prefix(matching prefix: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let folded = LookupKey.fold(prefix)
        return Array(keys.lazy.filter { $0.hasPrefix(folded) }.prefix(limit))
    }
    public var indexEntries: [IndexableEntry] { records }
    public var indexTitle: String { name }
    public var indexSourceURL: URL { sourceURL }
}
