// SPDX-License-Identifier: MIT
import Foundation

/// Converts a FreeDict TEI P5 `<entry>` body to HTML. A single-pass tokeniser
/// (same shape as `Xdxf2Html`) maps the TEI dictionary tag vocabulary to
/// `<div>/<span class="tei_…">`, turns `<ref>`/`<oRef>` into `bword:` links, and
/// numbers `<sense n="…">`. Unknown tags are dropped (text kept); inter-element
/// whitespace collapses under normal HTML flow. Tag set correlated with
/// pyglossary's FreeDict-P5 reader (GoldenDict has no TEI reader).
public enum Tei2Html {

    /// Inline tags → `<span class="tei_<value>">…</span>`.
    private static let spanClass: [String: String] = [
        "orth": "tei_orth", "quote": "tei_quote", "pron": "tei_pron",
        "pos": "tei_gram", "gen": "tei_gram", "num": "tei_gram", "number": "tei_gram",
        "itype": "tei_gram", "gram": "tei_gram", "subc": "tei_gram", "case": "tei_gram",
        "def": "tei_def", "usg": "tei_usg", "note": "tei_note", "lbl": "tei_lbl",
        "term": "tei_term", "mentioned": "tei_mentioned", "hi": "tei_hi",
    ]
    /// Block tags → `<div class="tei_<value>">…</div>`.
    private static let divClass: [String: String] = [
        "cit": "tei_cit", "eg": "tei_eg", "re": "tei_re",
    ]
    /// Structural tags whose markers we drop, keeping their content.
    private static let transparent: Set<String> = [
        "entry", "form", "gramgrp", "text", "body", "tei", "p", "hom", "xr", "dictscrap",
    ]

    public static func convert(_ tei: String) -> String {
        let chars = Array(tei)
        let n = chars.count
        var out = ""
        out.reserveCapacity(n + n / 4)

        // Capture inner text of <ref>/<oRef> to wrap it in an anchor on close.
        var capturing = false
        var captureBuf = ""

        var i = 0
        while i < n {
            let ch = chars[i]
            guard ch == "<" else {
                if capturing { captureBuf.append(ch) } else { out.append(ch) }
                i += 1
                continue
            }
            var j = i + 1
            while j < n, chars[j] != ">" { j += 1 }
            guard j < n else { if capturing { captureBuf += "&lt;" } else { out += "&lt;" }; i += 1; continue }
            let rawTag = String(chars[(i + 1)..<j])
            i = j + 1

            var s = rawTag
            let isClose = s.hasPrefix("/")
            if isClose { s.removeFirst() }
            if s.hasSuffix("/") { s.removeLast() }
            let name = String(s.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else { continue }
            let attrs = String(s.dropFirst(name.count))

            // <ref>/<oRef> → cross-reference link.
            if name == "ref" || name == "oref" {
                if isClose, capturing {
                    let word = XmlText.decodeEntities(XmlText.stripTags(captureBuf)).trimmingCharacters(in: .whitespaces)
                    let href = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
                    out += "<a href=\"bword:\(href)\" class=\"tei_ref\">\(captureBuf)</a>"
                    capturing = false; captureBuf = ""
                } else if !isClose {
                    capturing = true; captureBuf = ""
                }
                continue
            }

            let piece: String
            if name == "sense" {
                if isClose {
                    piece = "</div>"
                } else if let num = XmlText.attribute(attrs, "n") {
                    piece = "<div class=\"tei_sense\"><span class=\"tei_sensenum\">\(num).</span> "
                } else {
                    piece = "<div class=\"tei_sense\">"
                }
            } else if let cls = spanClass[name] {
                piece = isClose ? "</span>" : "<span class=\"\(cls)\">"
            } else if let cls = divClass[name] {
                piece = isClose ? "</div>" : "<div class=\"\(cls)\">"
            } else if transparent.contains(name) {
                continue                                  // drop marker, keep content
            } else {
                continue                                  // unknown tag — drop
            }
            if capturing { captureBuf += piece } else { out += piece }
        }

        if capturing { out += captureBuf }
        return "<div class=\"tei_entry\">" + out + "</div>"
    }
}
