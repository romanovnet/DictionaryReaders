// SPDX-License-Identifier: MIT
import Foundation

/// Reads a FreeDict TEI P5 dictionary — a single XML document (`.tei`, or
/// gzip-compressed `.tei.gz`) whose `<entry>` elements are articles. Like the
/// XDXF reader, we scan `<entry>…</entry>` spans (keeping inner markup for the
/// `Tei2Html` converter) rather than doing a full XML parse, with depth tracking
/// so a nested `<entry>` (inside `<re>`) doesn't truncate its parent.
///
/// Tag handling correlated with pyglossary's FreeDict-P5 reader (GoldenDict has
/// no TEI reader; it consumes FreeDict's *built* dictd/stardict/slob instead).
public struct TeiDictionary: Sendable {
    public let url: URL
    public let fullName: String?
    public let langFrom: String?
    public let langTo: String?

    private let headwordsByEntry: [[String]]
    private let bodies: [String]
    private let byFolded: [String: [Int]]
    private let sortedFolded: [String]

    public init(url: URL) async throws {
        self.url = url

        guard var data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw TeiError.fileNotReadable(url)
        }
        if Gzip.hasMagic(data) {
            guard let inflated = try? Gzip.decompress(data) else { throw TeiError.fileNotReadable(url) }
            data = inflated
        }
        let text = Self.decodeText(data)

        // Title from teiHeader; language pair from a `from-to` filename (FreeDict
        // convention) since 2-letter language fields are often absent.
        self.fullName = Self.firstMatch(in: Self.header(of: text), #"<title\b[^>]*>(.*?)</title>"#)
        let sourceURL = url.pathExtension.lowercased() == "gz" ? url.deletingPathExtension() : url
        let stem = sourceURL.deletingPathExtension().lastPathComponent.split(separator: "-")
        if stem.count == 2 { self.langFrom = String(stem[0]); self.langTo = String(stem[1]) }
        else { self.langFrom = nil; self.langTo = nil }

        let (headwords, bodies) = Self.parseEntries(text)
        guard !headwords.isEmpty else { throw TeiError.notTei(url) }

        var byFolded: [String: [Int]] = [:]
        byFolded.reserveCapacity(headwords.count)
        for (idx, words) in headwords.enumerated() {
            for w in words { byFolded[LookupKey.fold(w), default: []].append(idx) }
        }

        self.headwordsByEntry = headwords
        self.bodies = bodies
        self.byFolded = byFolded
        self.sortedFolded = byFolded.keys.sorted()
    }

    // MARK: - Parsing

    private static func decodeText(_ data: Data) -> String {
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if b0 == 0xFF, b1 == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            if b0 == 0xFE, b1 == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        }
        var d = data
        if d.count >= 3, d[d.startIndex] == 0xEF, d[d.startIndex + 1] == 0xBB, d[d.startIndex + 2] == 0xBF {
            d = d.dropFirst(3)
        }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    /// The portion before `<body…>` — where the teiHeader (and `<title>`) lives.
    private static func header(of text: String) -> String {
        if let r = text.range(of: "<body", options: .caseInsensitive) {
            return String(text[..<r.lowerBound])
        }
        return text
    }

    /// Scan top-level `<entry>…</entry>` spans with depth tracking (a nested
    /// `<entry>` inside `<re>` won't close its parent early). The `<entry`-name
    /// guard rejects `<entryFree>`.
    private static func parseEntries(_ text: String) -> ([[String]], [String]) {
        var headwords: [[String]] = []
        var bodies: [String] = []
        let end = text.endIndex
        var cursor = text.startIndex

        while let open = text.range(of: "<entry", options: .caseInsensitive, range: cursor..<end) {
            guard isElementName(text, after: open.upperBound),
                  let openGt = text.range(of: ">", range: open.upperBound..<end) else {
                cursor = open.upperBound
                continue
            }
            // Find the matching </entry> honouring nested <entry> opens.
            var depth = 1
            var scan = openGt.upperBound
            var contentEnd = end
            var matchEnd = end
            while depth > 0 {
                guard let close = text.range(of: "</entry>", options: .caseInsensitive, range: scan..<end) else { break }
                let nextOpen = text.range(of: "<entry", options: .caseInsensitive, range: scan..<close.lowerBound)
                if let o = nextOpen, isElementName(text, after: o.upperBound) {
                    depth += 1
                    scan = o.upperBound
                } else {
                    depth -= 1
                    if depth == 0 { contentEnd = close.lowerBound; matchEnd = close.upperBound }
                    else { scan = close.upperBound }
                }
            }
            let inner = String(text[openGt.upperBound..<contentEnd])
            let words = extractOrths(inner)
            if !words.isEmpty {
                headwords.append(words)
                bodies.append(inner)
            }
            cursor = matchEnd
        }
        return (headwords, bodies)
    }

    /// True when the char after `<entry` ends the element name (so `<entryFree>`
    /// and `<entryX>` don't match).
    private static func isElementName(_ text: String, after idx: String.Index) -> Bool {
        guard idx < text.endIndex else { return true }
        let c = text[idx]
        return c == ">" || c == " " || c == "\t" || c == "\n" || c == "\r" || c == "/"
    }

    /// All `<orth>…</orth>` headwords in an entry (tags stripped, entities decoded).
    private static func extractOrths(_ inner: String) -> [String] {
        var words: [String] = []
        let end = inner.endIndex
        var cursor = inner.startIndex
        while let open = inner.range(of: "<orth", options: .caseInsensitive, range: cursor..<end),
              let gt = inner.range(of: ">", range: open.upperBound..<end),
              let close = inner.range(of: "</orth>", options: .caseInsensitive, range: gt.upperBound..<end) {
            let form = XmlText.plain(String(inner[gt.upperBound..<close.lowerBound]))
            if !form.isEmpty, !words.contains(form) { words.append(form) }
            cursor = close.upperBound
        }
        return words
    }

    private static func firstMatch(in text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return XmlText.plain(ns.substring(with: m.range(at: 1)))
    }
}

extension TeiDictionary: DictionarySource {
    public var format: DictionaryFormat { .tei }

    public var title: String {
        if let name = fullName, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    public var languagePair: LanguagePair? {
        guard let from = langFrom, let to = langTo else { return nil }
        return LanguagePair(source: from, target: to)
    }

    public var headwordCount: Int { byFolded.count }

    public func lookup(exact headword: String) -> [DictionaryEntry] {
        let key = LookupKey.fold(headword)
        guard let indices = byFolded[key] else { return [] }
        let name = title
        return indices.map { idx in
            DictionaryEntry(
                headwords: headwordsByEntry[idx],
                markup: .html(Tei2Html.convert(bodies[idx])),
                sourceFormat: .tei,
                sourceTitle: name
            )
        }
    }

    public func allHeadwords() -> [String] { sortedFolded }

    public func prefix(matching prefix: String, limit: Int) -> [String] {
        let folded = LookupKey.fold(prefix)
        guard !folded.isEmpty else { return [] }
        var result: [String] = []
        var i = lowerBound(of: folded)
        while i < sortedFolded.endIndex, result.count < limit {
            let candidate = sortedFolded[i]
            guard candidate.hasPrefix(folded) else { break }
            result.append(candidate)
            i += 1
        }
        return result
    }

    private func lowerBound(of key: String) -> Int {
        var lo = 0, hi = sortedFolded.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedFolded[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

extension TeiDictionary: BodyIndexable {
    public var indexEntries: [IndexableEntry] {
        zip(headwordsByEntry, bodies).map { IndexableEntry(headwords: $0, body: $1) }
    }
    public var indexTitle: String { title }
    public var indexSourceURL: URL { url }
}

public enum TeiError: Error, Equatable {
    case fileNotReadable(URL)
    case notTei(URL)
}
