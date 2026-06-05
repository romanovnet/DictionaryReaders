// SPDX-License-Identifier: MIT
import Foundation

/// Wire identifiers mapped to platform encodings. No decoder code is vendored.
enum BglCharset {
    static func encoding(forCharsetCode code: UInt8) -> String.Encoding {
        let name: String
        switch code {
        case 0x43: name = "windows-1250"
        case 0x44: name = "windows-1251"
        case 0x45: name = "cp932"
        case 0x46: name = "big5"
        case 0x47: name = "gb18030"
        case 0x48: name = "windows-1257"
        case 0x49: name = "windows-1253"
        case 0x4a: name = "euc-kr"
        case 0x4b: name = "windows-1254"
        case 0x4c: name = "windows-1255"
        case 0x4d: name = "windows-1256"
        case 0x4e: name = "cp874"
        default: return .windowsCP1252
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
    static func partOfSpeech(_ code: UInt8) -> String? {
        // Wire code → grammatical category; ordinary labels, no imported parser.
        // Historical research and factual-table disposition: ORIGIN.md.
        switch code {
        case 48: return "noun"
        case 49: return "adjective"
        case 50: return "verb"
        case 51: return "adverb"
        case 52: return "interjection"
        case 53: return "pronoun"
        case 54: return "preposition"
        case 55: return "conjunction"
        case 56: return "suffix"
        case 57: return "prefix"
        case 58: return "article"
        case 60: return "abbreviation"
        case 61: return "masculine noun and adjective"
        case 62: return "feminine noun and adjective"
        case 63: return "masculine and feminine noun and adjective"
        case 64: return "feminine noun"
        case 65: return "masculine and feminine noun"
        case 66: return "masculine noun"
        case 67: return "numeral"
        case 68: return "participle"
        default: return nil
        }
    }
}
