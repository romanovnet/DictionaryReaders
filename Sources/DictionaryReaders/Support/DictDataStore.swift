// SPDX-License-Identifier: MIT
import Foundation

/// Article-data access shared by formats whose payload is a `.dict`/`.dict.dz`
/// blob addressed by `(offset, size)` — StarDict and DictD. Plain `.dict` is
/// memory-mapped and sliced directly; `.dict.dz` is read chunk-by-chunk via
/// `DictZip` (random access, no whole-file inflation). A `.dz` that isn't
/// dictzip (plain gzip, no `RA` subfield) falls back to whole inflation.
enum DictDataStore: Sendable {
    case plain(Data)
    case dictzip(DictZip)

    var count: Int {
        switch self {
        case .plain(let d): return d.count
        case .dictzip(let z): return z.uncompressedSize
        }
    }

    func bytes(offset: Int, size: Int) -> Data? {
        switch self {
        case .plain(let d):
            guard offset >= 0, size > 0, offset <= d.count, size <= d.count - offset else { return nil }
            return d.subdata(in: (d.startIndex + offset)..<(d.startIndex + offset + size))
        case .dictzip(let z):
            return try? z.read(offset: offset, size: size)
        }
    }

    /// Open `<base>.dict` (mapped) or `<base>.dict.dz` (dictzip, else whole
    /// inflation). Returns nil if neither file exists or can't be read.
    static func openDict(base: URL) -> DictDataStore? {
        let fm = FileManager.default
        let plain = base.appendingPathExtension("dict")
        let dz = base.appendingPathExtension("dict.dz")

        if fm.fileExists(atPath: plain.path) {
            guard let d = try? Data(contentsOf: plain, options: [.mappedIfSafe]) else { return nil }
            return .plain(d)
        }
        if fm.fileExists(atPath: dz.path) {
            guard let raw = try? Data(contentsOf: dz, options: [.mappedIfSafe]) else { return nil }
            if let z = DictZip(raw) { return .dictzip(z) }
            guard let inflated = try? Gzip.decompress(raw) else { return nil }
            return .plain(inflated)
        }
        return nil
    }
}
