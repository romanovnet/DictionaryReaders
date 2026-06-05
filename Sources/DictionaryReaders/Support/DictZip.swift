// SPDX-License-Identifier: MIT
import Foundation

/// Random-access reader for **dictzip** files (`.dict.dz`, `.dsl.dz`-style
/// gzip with a dictzip index). A dictzip file is a valid gzip stream carrying a
/// `RA` (Random Access) subfield in its `FEXTRA` header: the uncompressed data
/// is split into fixed-size chunks (`CHLEN` bytes each), every chunk
/// independently inflatable because the compressor inserts `Z_FULL_FLUSH` at
/// chunk boundaries. The subfield lists each chunk's *compressed* length, so we
/// can seek to the chunk(s) covering a byte range and inflate only those —
/// instead of decompressing the whole file into RAM.
///
/// The backing file is held **memory-mapped** (pages fault in as chunks are
/// read), so a multi-MB `.dict.dz` costs almost no resident memory until
/// articles are actually looked up. Correlated with GoldenDict-ng's use of the
/// `dictzip` library (`dict_data_read_`) and the dictzip(1) `RA` subfield spec.
///
/// A small LRU caches recently-inflated chunks: consecutive articles (and prefix
/// browsing) frequently fall in the same ~chunk, so this avoids re-inflating it
/// on every lookup. `@unchecked Sendable` — the cache is lock-guarded and the
/// rest of the state is immutable, so concurrent reads are safe.
public struct DictZip: @unchecked Sendable {
    public let chunkLength: Int
    public let uncompressedSize: Int

    private let data: Data            // mapped whole .dz file
    private let chunkStarts: [Int]    // absolute (relative-to-startIndex) offset of each chunk's compressed bytes
    private let chunkCompLengths: [Int]
    private let chunkCache = LRUCache<Int, Data>(capacity: 16)   // ~16 × chunkLength

    /// Parse a dictzip file. Returns nil if `data` is not gzip or lacks the `RA`
    /// subfield (i.e. a plain gzip — caller should fall back to whole inflate).
    public init?(_ data: Data) {
        let n = data.count
        func b(_ rel: Int) -> UInt8 { data[data.startIndex + rel] }
        func u16(_ rel: Int) -> Int { Int(b(rel)) | (Int(b(rel + 1)) << 8) }

        guard n >= 20, b(0) == 0x1F, b(1) == 0x8B, b(2) == 0x08 else { return nil }
        let flg = b(3)
        guard flg & 0x04 != 0 else { return nil }            // FEXTRA required

        let xlen = u16(10)
        let extraStart = 12
        let extraEnd = extraStart + xlen
        guard extraEnd <= n else { return nil }

        // Scan FEXTRA subfields for 'RA'.
        var chlen = 0
        var comp: [Int] = []
        var p = extraStart
        while p + 4 <= extraEnd {
            let si1 = b(p), si2 = b(p + 1)
            let sublen = u16(p + 2)
            let subStart = p + 4
            let subEnd = subStart + sublen
            guard subEnd <= extraEnd else { break }
            if si1 == 0x52, si2 == 0x41 {                    // 'R','A'
                guard sublen >= 6, u16(subStart) == 1 else { return nil }   // VER == 1
                chlen = u16(subStart + 2)
                let chcnt = u16(subStart + 4)
                guard chcnt > 0, subStart + 6 + chcnt * 2 <= subEnd else { return nil }
                comp.reserveCapacity(chcnt)
                var q = subStart + 6
                for _ in 0..<chcnt { comp.append(u16(q)); q += 2 }
            }
            p = subEnd
        }
        guard chlen > 0, !comp.isEmpty else { return nil }

        // Skip the rest of the gzip header (FNAME/FCOMMENT/FHCRC) to the data.
        var hp = extraEnd
        if flg & 0x08 != 0 { while hp < n, b(hp) != 0 { hp += 1 }; hp += 1 }   // FNAME
        if flg & 0x10 != 0 { while hp < n, b(hp) != 0 { hp += 1 }; hp += 1 }   // FCOMMENT
        if flg & 0x02 != 0 { hp += 2 }                                          // FHCRC
        guard hp <= n else { return nil }

        var starts: [Int] = []
        starts.reserveCapacity(comp.count)
        var off = hp
        for len in comp { starts.append(off); off += len }
        guard off <= n - 8 else { return nil }                   // chunk table must fit the file

        // gzip ISIZE trailer (uncompressed size mod 2³²); fall back to an upper
        // bound if absent/zero — it's only used for a bounds guard.
        let isize = Int(b(n - 4)) | (Int(b(n - 3)) << 8) | (Int(b(n - 2)) << 16) | (Int(b(n - 1)) << 24)

        self.data = data
        self.chunkLength = chlen
        self.chunkCompLengths = comp
        self.chunkStarts = starts
        self.uncompressedSize = isize > 0 ? isize : comp.count * chlen
    }

    /// Read `size` uncompressed bytes starting at `offset`, inflating only the
    /// chunk(s) that cover the range.
    public func read(offset: Int, size: Int) throws -> Data {
        guard offset >= 0, size >= 0, offset <= uncompressedSize,
              size <= uncompressedSize - offset else { throw DictZipError.outOfRange }
        guard size > 0 else { return Data() }
        let first = offset / chunkLength
        let last = (offset + size - 1) / chunkLength
        guard first < chunkStarts.count, last < chunkStarts.count else { throw DictZipError.outOfRange }

        var buffer = Data()
        buffer.reserveCapacity((last - first + 1) * chunkLength)
        for i in first...last {
            guard let chunk = inflateChunk(i) else { throw DictZipError.inflateFailed }
            buffer.append(chunk)
        }
        let localStart = offset - first * chunkLength
        let end = localStart + size
        guard end <= buffer.count else { throw DictZipError.outOfRange }
        return buffer.subdata(in: localStart..<end)
    }

    private func inflateChunk(_ i: Int) -> Data? {
        if let hit = chunkCache.value(for: i) { return hit }
        let start = data.startIndex + chunkStarts[i]
        let comp = data.subdata(in: start..<(start + chunkCompLengths[i]))
        guard let out = Gzip.inflateChunk(comp, maxSize: chunkLength) else { return nil }
        chunkCache.insert(out, for: i)
        return out
    }
}

public enum DictZipError: Error, Equatable {
    case outOfRange
    case inflateFailed
}
