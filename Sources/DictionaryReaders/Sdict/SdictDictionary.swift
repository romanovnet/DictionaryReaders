// SPDX-License-Identifier: MIT
import Foundation

/// Reads an SDictionary (PtkSoft) `.dct` archive — the legacy format produced by
/// PtkSoft's *Sdict* tools and read by the *sdictviewer* app (Igor Tkach, later
/// the author of Aard/slob). A `.dct` is a 43-byte header + a *full index* (a
/// sequential list of `word → article pointer`) + a blob of length-prefixed,
/// individually compressed articles.
///
/// Uses a mapped file and a lock-protected article cache. Compression is none
/// or zlib; bzip2 is unsupported. Source comparison references are in ORIGIN.md.
public struct SdictDictionary: @unchecked Sendable {
    public static let magic: [UInt8] = Array("sdct".utf8)   // 73 64 63 74

    public let fileURL: URL

    private let data: Data
    private let compression: Int          // header byte & 0x0F: 0 none, 1 zlib, 2 bzip2
    private let articlesOffset: Int

    private let words: [String]           // display headwords, in file order
    private let folded: [String]          // case/diacritic fold of `words`
    private let articlePtrs: [UInt32]     // article offsets, relative to `articlesOffset`
    private let order: [Int]              // indices into the above, sorted by `folded`
    private let pair: LanguagePair?
    private let name: String

    private let articleCache = LRUCache<Int, String>(capacity: 64)

    public init(url: URL) async throws {
        self.fileURL = url
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count > 43 else {
            throw SdictError.fileNotReadable(url)
        }
        guard [UInt8](data.prefix(Self.magic.count)) == Self.magic else { throw SdictError.notSdict(url) }
        self.data = data

        // Header (little-endian). signature(4) + inputLang(3) + outputLang(3) +
        // compression(1) + 8×u32 = 43 bytes.
        let inputLang = Self.langCode(data, 4)
        let outputLang = Self.langCode(data, 7)
        let compression = Int(Self.u8(data, 10) & 0x0F)
        let wordCount = Int(Self.u32(data, 11))
        // 15: shortIndexLength, 31: shortIndexOffset — both unused (we walk the full index).
        let titleOffset = Int(Self.u32(data, 19))
        let fullIndexOffset = Int(Self.u32(data, 35))
        let articlesOffset = Int(Self.u32(data, 39))
        self.compression = compression
        self.articlesOffset = articlesOffset
        guard wordCount > 0, wordCount <= (data.count - 43) / 8 else { throw SdictError.noEntries(url) }
        guard compression != 2 else { throw SdictError.unsupportedCompression("bzip2") }
        guard compression == 0 || compression == 1 else { throw SdictError.unsupportedCompression("code \(compression)") }

        // Walk the full index: each entry is `next_word u16` (total record size,
        // including the 8-byte header), `prev_word u16` (unused), `article_ptr
        // u32`, then `next_word - 8` UTF-8 word bytes. Advance by `next_word`.
        var words = [String](); words.reserveCapacity(wordCount)
        var ptrs = [UInt32](); ptrs.reserveCapacity(wordCount)
        var pos = fullIndexOffset
        for _ in 0..<wordCount {
            guard pos + 8 <= data.count else { break }
            let nextWord = Int(Self.u16(data, pos))
            guard nextWord >= 8 else { break }
            let articlePtr = Self.u32(data, pos + 4)
            let wordLen = nextWord - 8
            let s = data.startIndex + pos + 8
            guard s + wordLen <= data.endIndex else { break }
            words.append(String(decoding: data[s..<(s + wordLen)], as: UTF8.self))
            ptrs.append(articlePtr)
            pos += nextWord
        }
        guard !words.isEmpty else { throw SdictError.noEntries(url) }
        self.words = words
        self.articlePtrs = ptrs
        let folded = words.map(LookupKey.fold)
        self.folded = folded
        var order = Array(0..<words.count)
        order.sort { folded[$0] != folded[$1] ? folded[$0] < folded[$1] : $0 < $1 }
        self.order = order

        self.pair = inputLang.isEmpty || outputLang.isEmpty
            ? nil : LanguagePair(source: inputLang, target: outputLang)

        // Title: u32 length + (compressed) UTF-8 — same codec as articles.
        let title = Self.readString(data, at: titleOffset, compression: compression)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }

    // MARK: - Lookup helpers

    /// First position in `order` whose folded word is ≥ `target`.
    private func lowerBound(_ target: String) -> Int {
        var lo = 0, hi = order.count
        while lo < hi {
            let m = (lo + hi) / 2
            if folded[order[m]] < target { lo = m + 1 } else { hi = m }
        }
        return lo
    }

    // MARK: - Article reading

    /// A `u32 length` + that many (optionally compressed) bytes at `offset`.
    private static func readString(_ d: Data, at offset: Int, compression: Int) -> String? {
        guard offset >= 0, offset + 4 <= d.count else { return nil }
        let len = Int(u32(d, offset))
        let s = d.startIndex + offset + 4
        guard s + len <= d.endIndex else { return nil }
        let raw = d.subdata(in: s..<(s + len))
        let bytes: Data?
        switch compression {
        case 0: bytes = raw
        case 1: bytes = Gzip.inflateZlib(raw)
        default: bytes = nil
        }
        return bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    private func article(at pointer: UInt32) -> String? {
        let key = Int(pointer)
        if let hit = articleCache.value(for: key) { return hit }
        guard let raw = Self.readString(data, at: articlesOffset + key, compression: compression) else { return nil }
        let html = Self.convert(raw)
        articleCache.insert(html, for: key)
        return html
    }

    /// SDict article markup → HTML. The one substantive tag is `<r>WORD</r>`, a
    /// cross-reference to another headword → a `bword:` link the article view
    /// resolves via `DictionaryLink`. `<br>` becomes a hard break; bare newlines
    /// too. Other tags (`<b>`/`<i>`/`<u>`/`<p>`/`<t>`…) are already HTML-renderable
    /// and pass through.
    static func convert(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<br>", with: "<br/>")
            .replacingOccurrences(of: "<BR>", with: "<br/>")
        // <r>target</r> → <a href="bword:target">target</a>
        if out.contains("<r>"), let re = try? NSRegularExpression(pattern: "<r>(.*?)</r>", options: [.dotMatchesLineSeparators]) {
            let ns = out as NSString
            let m = NSMutableString()
            var last = 0
            for match in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                m.append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
                let inner = ns.substring(with: match.range(at: 1))
                let target = inner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? inner
                m.append("<a href=\"bword:\(target)\">\(inner)</a>")
                last = match.range.location + match.range.length
            }
            m.append(ns.substring(from: last))
            out = m as String
        }
        return out.replacingOccurrences(of: "\n", with: "<br/>")
    }

    // MARK: - byte readers (little-endian)

    private static func u8(_ d: Data, _ off: Int) -> UInt8 { d[d.startIndex + off] }
    private static func u16(_ d: Data, _ off: Int) -> UInt16 {
        let s = d.startIndex + off; return UInt16(d[s]) | UInt16(d[s + 1]) << 8
    }
    private static func u32(_ d: Data, _ off: Int) -> UInt32 {
        let s = d.startIndex + off
        return UInt32(d[s]) | UInt32(d[s+1]) << 8 | UInt32(d[s+2]) << 16 | UInt32(d[s+3]) << 24
    }
    /// A fixed 3-byte ISO 639 language slot, NUL/space-trimmed.
    private static func langCode(_ d: Data, _ off: Int) -> String {
        let s = d.startIndex + off
        let raw = String(decoding: d[s..<(s + 3)], as: UTF8.self)
        return String(raw.prefix { $0 != "\u{0}" }).trimmingCharacters(in: .whitespaces)
    }
}

extension SdictDictionary: DictionarySource {
    public var format: DictionaryFormat { .sdict }
    public var title: String { name }
    public var languagePair: LanguagePair? { pair }
    public var headwordCount: Int { words.count }

    public func lookup(exact headword: String) -> [DictionaryEntry] {
        let target = LookupKey.fold(headword)
        guard !target.isEmpty else { return [] }
        let name = title
        var results: [DictionaryEntry] = []
        var i = lowerBound(target)
        while i < order.count {
            let idx = order[i]
            guard folded[idx] == target else { break }
            if let html = article(at: articlePtrs[idx]) {
                results.append(DictionaryEntry(headwords: [words[idx]], markup: .html(html),
                                               sourceFormat: .sdict, sourceTitle: name))
            }
            i += 1
        }
        return results
    }

    public func allHeadwords() -> [String] { words }

    public func prefix(matching prefix: String, limit: Int) -> [String] {
        let folded = LookupKey.fold(prefix)
        guard !folded.isEmpty else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        var i = lowerBound(folded)
        while i < order.count, result.count < limit {
            let fk = self.folded[order[i]]
            guard fk.hasPrefix(folded) else { break }
            if seen.insert(fk).inserted { result.append(words[order[i]]) }
            i += 1
        }
        return result
    }
}

public enum SdictError: Error, Equatable {
    case fileNotReadable(URL)
    case notSdict(URL)
    case unsupportedCompression(String)
    case noEntries(URL)
}
