// SPDX-License-Identifier: MIT
import Foundation

/// Converts a DictD article (preformatted plain text) to HTML for a caller. DictD bodies are whitespace-significant, so we wrap in `<pre>` and
/// HTML-escape. Two conventional inline markups are recognised (per
/// GoldenDict-ng `dictdfiles.cc`): `{word}` cross-references become `bword:`
/// links and `\text\`
/// phonetics become a styled span.
enum DictdArticle {
    static func html(_ text: String) -> String {
        var out = "<pre class=\"dictd_article\">"
        out.reserveCapacity(text.count + 32)

        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let c = text[i]
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"

            case "{":   // cross-reference {word}
                if let close = text[i...].firstIndex(of: "}") {
                    let word = String(text[text.index(after: i)..<close])
                    let href = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
                    out += "<a href=\"bword:\(href)\">\(escape(word))</a>"
                    i = close                       // trailing index(after:) skips '}'
                } else {
                    out += "{"
                }

            case "\\":  // phonetic \text\
                let bodyStart = text.index(after: i)
                if let close = text[bodyStart...].firstIndex(of: "\\") {
                    let phon = String(text[bodyStart..<close])
                    out += "<span class=\"dictd_phonetic\">\(escape(phon))</span>"
                    i = close                       // trailing index(after:) skips closing '\'
                } else {
                    out += "\\"
                }

            default:
                out.append(c)
            }
            i = text.index(after: i)
        }

        out += "</pre>"
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
