// SPDX-License-Identifier: MIT
import Foundation

/// Best-effort media type for a dictionary resource path.
enum ResourceMIME {
    static func type(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "m4a", "aac": return "audio/mp4"
        case "spx": return "audio/ogg"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "html", "htm": return "text/html"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }
}
