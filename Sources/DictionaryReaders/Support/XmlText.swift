// SPDX-License-Identifier: MIT
import Foundation

/// XML entity decoding and tag stripping for dictionary keys and titles.
enum XmlText {
    /// Remove all `<…>` tags, keeping the text between them.
    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Decode the five predefined XML entities plus numeric character refs
    /// (`&#233;`, `&#xE9;`). `&amp;` is done last so we don't re-decode.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        return replaceNumericRefs(named).replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Strip tags, decode entities, and trim — the plain key form of markup.
    static func plain(_ s: String) -> String {
        decodeEntities(stripTags(s)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract `name="value"` (or single-quoted) from a tag's attribute string.
    static func attribute(_ attrs: String, _ name: String) -> String? {
        guard let r = attrs.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = attrs[r.upperBound...].drop { $0 == " " }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let body = rest.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return nil }
        let value = String(body[..<close])
        return value.isEmpty ? nil : value
    }

    private static func replaceNumericRefs(_ s: String) -> String {
        guard s.contains("&#"), let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
