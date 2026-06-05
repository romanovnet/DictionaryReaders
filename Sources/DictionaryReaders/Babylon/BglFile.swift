// SPDX-License-Identifier: MIT
import Foundation

/// Wire framing only. Format observations and provenance: ORIGIN.md.
struct BglFile {
    struct Block { let type: Int; let data: Data }
    let blocks: [Block]
    init(url: URL) throws {
        guard let file = try? Data(contentsOf: url) else { throw BabylonError.fileNotReadable(url) }
        var header = ReaderBytes(file)
        guard let magic = header.number(4), [0x12340001, 0x12340002].contains(magic),
              let start = header.number(2), start >= 6, start < file.count else { throw BabylonError.badHeader }
        guard let inflated = try? Gzip.decompress(file.subdata(in: start..<file.count)) else {
            throw BabylonError.decompressionFailed
        }
        var stream = ReaderBytes(inflated)
        var result: [Block] = []
        while let tag = stream.number(1) {
            let sizeTag = tag >> 4
            let length = sizeTag >= 4 ? sizeTag - 4 : stream.number(sizeTag + 1)
            guard let length, let bytes = stream.take(length) else { throw BabylonError.badHeader }
            result.append(Block(type: tag & 15, data: bytes))
        }
        blocks = result
    }
}
public enum BabylonError: Error, Equatable {
    case fileNotReadable(URL), badHeader, decompressionFailed, noEntries(URL)
}
