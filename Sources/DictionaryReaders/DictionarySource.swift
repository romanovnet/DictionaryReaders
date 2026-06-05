// SPDX-License-Identifier: MIT
import Foundation

/// Formats decoded by this package. No file discovery or downloading is performed.
public enum DictionaryFormat: String, Sendable, CaseIterable {
    case appleDictionary
    case babylon
    case sdict
    case dictd
    case tei
}

public struct LanguagePair: Sendable, Hashable {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// Reader output is HTML; callers choose how to render or sanitize it.
public struct EntryMarkup: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case html(String)
        case unavailable(reason: String)
    }
    public let body: Body
    public init(body: Body) { self.body = body }
    public static func html(_ text: String) -> Self { Self(body: .html(text)) }
    public static func unavailable(reason: String) -> Self { Self(body: .unavailable(reason: reason)) }
    /// HTML content, or an escaped diagnostic when an article cannot be read.
    public var html: String {
        switch body {
        case .html(let text): return text
        case .unavailable(let reason):
            let escaped = reason.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<p>Article unavailable: \(escaped)</p>"
        }
    }
}

public struct DictionaryEntry: Sendable, Equatable {
    public let headwords: [String]
    public let markup: EntryMarkup
    public let sourceFormat: DictionaryFormat
    public let sourceTitle: String
    public init(headwords: [String], markup: EntryMarkup, sourceFormat: DictionaryFormat, sourceTitle: String) {
        self.headwords = headwords
        self.markup = markup
        self.sourceFormat = sourceFormat
        self.sourceTitle = sourceTitle
    }
}

public protocol DictionarySource: Sendable {
    var format: DictionaryFormat { get }
    var title: String { get }
    var languagePair: LanguagePair? { get }
    var headwordCount: Int { get }
    var embeddedIconData: Data? { get }
    func lookup(exact headword: String) -> [DictionaryEntry]
    func prefix(matching prefix: String, limit: Int) -> [String]
    func allHeadwords() -> [String]
}

public extension DictionarySource {
    var embeddedIconData: Data? { nil }
}

/// Optional access to resources contained in a dictionary bundle.
public protocol DictionaryResourceProvider: Sendable {
    func resource(forPath path: String) -> (data: Data, mimeType: String)?
}

/// Original headwords and stored article text for a caller's index.
/// TEI stores raw entry XML; render it through Tei2Html.convert. Apple/Babylon store HTML.
public struct IndexableEntry: Sendable {
    public let headwords: [String]
    public let body: String
    public init(headwords: [String], body: String) {
        self.headwords = headwords
        self.body = body
    }
}

/// Enumeration can read/decompress every article. The package stores no database.
public protocol BodyIndexable: Sendable {
    var indexEntries: [IndexableEntry] { get }
    var indexTitle: String { get }
    var indexSourceURL: URL { get }
    var indexCSS: String? { get }
}

public extension BodyIndexable {
    var indexCSS: String? { nil }
}

enum LookupKey {
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
