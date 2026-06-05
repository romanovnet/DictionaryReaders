// SPDX-License-Identifier: MIT
import Foundation

/// Reads a DictD (DICT protocol) dictionary: a `.index` text file pairing each
/// headword with a `(offset, size)` into a `.dict`/`.dict.dz` data file. The
/// `.index` is the identity; the data file is derived from its basename.
///
/// `.index` lines are `headword<TAB>offset<TAB>size`, where offset and size are
/// **base64** big-endian positional numbers (alphabet
/// `A–Z a–z 0–9 + /`). The `.dict.dz` is dictzip — read via `DictZip` random
/// access (shared with StarDict through `DictDataStore`). Correlated with
/// GoldenDict-ng `dictdfiles.cc` + the dictd(8) format.
public struct DictdDictionary: Sendable {
    public let indexURL: URL
    public let name: String?

    private let words: [String]
    private let offsets: [Int]
    private let sizes: [Int]
    private let dict: DictDataStore
    private let byFolded: [String: [Int]]
    private let sortedFolded: [String]

    public init(indexURL: URL) async throws {
        self.indexURL = indexURL

        guard let indexData = Self.readIndex(indexURL) else {
            throw DictdError.fileNotReadable(indexURL)
        }
        let (words, offsets, sizes) = Self.parseIndex(indexData)
        guard !words.isEmpty else { throw DictdError.emptyIndex(indexURL) }

        let base = indexURL.deletingPathExtension()   // drops ".index"
        guard let store = DictDataStore.openDict(base: base) else {
            throw DictdError.missingDataFile(base: base)
        }

        // Index real headwords for lookup; the `00-database-*` control entries
        // are metadata, not searchable words.
        var byFolded: [String: [Int]] = [:]
        byFolded.reserveCapacity(words.count)
        for (idx, word) in words.enumerated() where !Self.isControlEntry(word) {
            byFolded[LookupKey.fold(word), default: []].append(idx)
        }

        self.words = words
        self.offsets = offsets
        self.sizes = sizes
        self.dict = store
        self.byFolded = byFolded
        self.sortedFolded = byFolded.keys.sorted()
        self.name = Self.extractShortName(words: words, offsets: offsets, sizes: sizes, dict: store)
    }

    // MARK: - Index

    /// Cheap headword count for previews (e.g. the Add… review sheet): the number of `.index`
    /// lines (one per headword), transparently inflating a `.index.gz`/`.index.dz`. No full
    /// parse of offsets/sizes. `nil` if the index can't be read. Safe to call off the main actor.
    public static func headwordCount(indexURL: URL) -> Int? {
        guard let data = readIndex(indexURL) else { return nil }
        // Each non-empty newline-separated line is one `headword<TAB>offset<TAB>size` entry.
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    /// Read `.index`, transparently inflating a `.index.gz`/`.index.dz` sibling.
    private static func readIndex(_ url: URL) -> Data? {
        if let d = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return Gzip.hasMagic(d) ? try? Gzip.decompress(d) : d
        }
        let base = url.deletingPathExtension()
        for ext in ["index.gz", "index.dz"] {
            let alt = base.appendingPathExtension(ext)
            if let raw = try? Data(contentsOf: alt), let inflated = try? Gzip.decompress(raw) {
                return inflated
            }
        }
        return nil
    }

    private static func parseIndex(_ data: Data) -> ([String], [Int], [Int]) {
        var words: [String] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let offset = decodeBase64(fields[1]),
                  let size = decodeBase64(fields[2]) else { continue }
            let word = String(fields[0])
            guard !word.isEmpty else { continue }
            words.append(word)
            offsets.append(offset)
            sizes.append(size)
        }
        return (words, offsets, sizes)
    }

    /// DictD offsets/sizes are base64 big-endian positional numbers.
    private static let base64Values: [Int] = {
        var table = [Int](repeating: -1, count: 128)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (i, c) in alphabet.utf8.enumerated() { table[Int(c)] = i }
        return table
    }()

    private static func decodeBase64(_ s: Substring) -> Int? {
        guard !s.isEmpty else { return nil }
        var n = 0
        for c in s.utf8 {
            guard c < 128 else { return nil }
            let v = base64Values[Int(c)]
            guard v >= 0 else { return nil }
            let (scaled, multiplyOverflow) = n.multipliedReportingOverflow(by: 64)
            let (next, addOverflow) = scaled.addingReportingOverflow(v)
            guard !multiplyOverflow, !addOverflow else { return nil }
            n = next
        }
        return n
    }

    private static func isControlEntry(_ word: String) -> Bool {
        word.hasPrefix("00-database") || word.hasPrefix("00database")
    }

    /// Title from the `00-database-short` control entry: its article's first
    /// line is the headword; the next non-empty line is the short name.
    private static func extractShortName(words: [String], offsets: [Int], sizes: [Int], dict: DictDataStore) -> String? {
        guard let idx = words.firstIndex(where: {
            let w = $0.lowercased()
            return w == "00-database-short" || w == "00databaseshort"
        }) else { return nil }
        guard let bytes = dict.bytes(offset: offsets[idx], size: sizes[idx]) else { return nil }
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Articles

    private func article(at index: Int) -> EntryMarkup {
        let offset = offsets[index], size = sizes[index]
        guard offset >= 0, size > 0, offset <= dict.count, size <= dict.count - offset,
              let bytes = dict.bytes(offset: offset, size: size) else {
            return .unavailable(reason: "out-of-range article")
        }
        return .html(DictdArticle.html(String(decoding: bytes, as: UTF8.self)))
    }
}

extension DictdDictionary: DictionarySource {
    public var format: DictionaryFormat { .dictd }

    public var title: String {
        if let name, !name.isEmpty { return name }
        return indexURL.deletingPathExtension().lastPathComponent
    }

    public var languagePair: LanguagePair? { nil }   // not encoded in the format

    public var headwordCount: Int { byFolded.count }

    public func lookup(exact headword: String) -> [DictionaryEntry] {
        let key = LookupKey.fold(headword)
        guard let indices = byFolded[key] else { return [] }
        let name = title
        return indices.map { idx in
            DictionaryEntry(
                headwords: [words[idx]],
                markup: article(at: idx),
                sourceFormat: .dictd,
                sourceTitle: name
            )
        }
    }

    public func allHeadwords() -> [String] { words }

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

public enum DictdError: Error, Equatable {
    case fileNotReadable(URL)
    case emptyIndex(URL)
    case missingDataFile(base: URL)
}
