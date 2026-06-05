// SPDX-License-Identifier: MIT
import Foundation

/// Text grammar for BGL records. Charset scopes are parsed recursively, and
/// metadata fields are decoded separately from the HTML payload.
/// See ORIGIN.md for evidence and remaining provenance limits.
enum BglText {
    static func decode(_ bytes: [UInt8], _ encoding: String.Encoding) -> String {
        String(data: Data(bytes), encoding: encoding) ?? String(data: Data(bytes), encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
    }
    static func stripDollarIndexes(_ bytes: [UInt8]) -> [UInt8] {
        // A lossless one-byte view permits matching ASCII markers around any encoding.
        let wire = String(bytes.map { Character(Unicode.Scalar(Int($0))!) })
        let cleaned = wire.replacingOccurrences(of: #"\$[0-9]+\$|\${2,}"#, with: "", options: .regularExpression)
        return cleaned.unicodeScalars.map { UInt8($0.value) }
    }
    static func processKey(_ bytes: [UInt8], sourceEncoding: String.Encoding) -> String {
        let text = decode(stripDollarIndexes(bytes), sourceEncoding)
        return clean(XmlText.decodeEntities(XmlText.stripTags(text)), singleLine: true)
    }
    private static func clean(_ text: String, singleLine: Bool = false) -> String {
        let scalars = text.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: singleLine ? #"[\r\n]+"# : #"\r\n?|\n+"#,
                                  with: singleLine ? " " : "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private enum Charset {
        case encoding(String.Encoding)
        case unicodeHex
        func render(_ bytes: [UInt8]) -> String {
            switch self {
            case .encoding(let value): return BglText.decode(bytes, value)
            case .unicodeHex:
                let words = String(decoding: bytes, as: UTF8.self).split(separator: ";")
                let units = words.compactMap { word -> UInt16? in
                    let hex = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return hex.count == 4 ? UInt16(hex, radix: 16) : nil
                }
                return String(decoding: units, as: UTF16.self)
            }
        }
    }
    static func decodeCharsetTags(_ bytes: [UInt8], defaultEncoding: String.Encoding, sourceEncoding: String.Encoding) -> String {
        let wire = String(bytes.map { Character(Unicode.Scalar(Int($0))!) }) as NSString
        let regex = try! NSRegularExpression(pattern: #"(?i)<charset\s+[^>]*>|</charset\s*>"#)
        let tags = regex.matches(in: wire as String, range: NSRange(location: 0, length: wire.length))
        var token = 0, position = 0
        func read(_ mode: Charset, depth: Int) -> String {
            var output = ""
            while token < tags.count {
                let range = tags[token].range
                output += mode.render(Array(bytes[position..<range.location]))
                position = NSMaxRange(range); token += 1
                let tag = wire.substring(with: range).lowercased()
                if tag.hasPrefix("</") { if depth > 0 { return output }; continue }
                let pattern = #"\bc\s*=\s*["']?([a-z])"#
                let codeRegex = try! NSRegularExpression(pattern: pattern)
                let tagNS = tag as NSString
                let code = codeRegex.firstMatch(in: tag, range: NSRange(location: 0, length: tagNS.length))
                    .map { tagNS.substring(with: $0.range(at: 1)) }
                let child: Charset
                switch code {
                case "u": child = .encoding(.utf8)
                case "k", "e": child = .encoding(sourceEncoding)
                case "g": child = .encoding(BglCharset.encoding(forCharsetCode: 0x47))
                case "t": child = .unicodeHex
                default: child = mode
                }
                // Bound recursion on hostile markup without changing ordinary nesting.
                if depth >= 64 {
                    output += mode.render(Array(bytes[position...])); position = bytes.count; token = tags.count
                    return output
                }
                output += read(child, depth: depth + 1)
            }
            output += mode.render(Array(bytes[position...])); position = bytes.count
            return output
        }
        return read(.encoding(defaultEncoding), depth: 0)
    }
    /// A trailer is accepted only if every field fits and the chain reaches EOF.
    /// This distinguishes embedded control bytes from metadata without copying
    /// the former reader's special case for a space after 0x14.
    private struct TrailerField {
        let tag: UInt8
        let payload: Range<Int>

        static func read(_ bytes: [UInt8], at offset: Int) -> Self? {
            let tag = bytes[offset]
            var start = offset + 1
            let size: Int
            switch tag {
            case 2, 6: size = 1
            case 7: size = 2
            case 0x40...0x4f: size = Int(tag) - 0x3e
            case 0x13, 0x18, 0x1a, 0x28, 0x50, 0x60:
                // Extended records carry a one-byte subtype before the length.
                if tag == 0x50 || tag == 0x60 { start += 1 }
                let width = tag == 0x28 || tag == 0x60 ? 2 : 1
                guard width <= bytes.count - start else { return nil }
                size = bytes[start..<start + width].reduce(0) { $0 * 256 + Int($1) }
                start += width
            default: return nil
            }
            guard start <= bytes.count, size <= bytes.count - start else { return nil }
            return Self(tag: tag, payload: start..<start + size)
        }
    }

    static func processDefi(_ bytes: [UInt8], sourceEncoding: String.Encoding, targetEncoding: String.Encoding) -> String {
        // Work backwards once: valid suffixes share their already-checked tails.
        // Unlike retrying a parser for each marker, this also bounds hostile input.
        var suffixes: [Int: TrailerField] = [:]
        var split: Int?
        for offset in bytes.indices.reversed() {
            if bytes[offset] == 0x14, suffixes[offset + 1] != nil { split = offset }
            if let field = TrailerField.read(bytes, at: offset),
               field.payload.upperBound == bytes.count || suffixes[field.payload.upperBound] != nil {
                suffixes[offset] = field
            }
        }
        let body = clean(decodeCharsetTags(Array(bytes[..<(split ?? bytes.count)]), defaultEncoding: targetEncoding, sourceEncoding: sourceEncoding))
        guard let split else { return body }
        var position = split + 1
        var partOfSpeech: String?, alternateTitle: String?
        while let field = suffixes[position] {
            switch field.tag {
            case 2:
                if let pos = BglCharset.partOfSpeech(bytes[field.payload.lowerBound]) {
                    partOfSpeech = "<em class=\"bgl-pos\">\(pos)</em>"
                }
            case 0x18:
                alternateTitle = clean(XmlText.decodeEntities(decodeCharsetTags(Array(bytes[field.payload]), defaultEncoding: sourceEncoding, sourceEncoding: sourceEncoding)))
            default: break
            }
            position = field.payload.upperBound
        }
        let title = [partOfSpeech, alternateTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return [title, body].filter { !$0.isEmpty }.joined(separator: "<br>\n")
    }
}
