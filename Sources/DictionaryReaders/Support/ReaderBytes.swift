// SPDX-License-Identifier: MIT
import Foundation

/// Bounds-checked wire cursor for the replacement dictionary readers.
/// Integers are unsigned on disk; offsets are checked before slicing.
struct ReaderBytes {
    let data: Data
    private(set) var offset: Int = 0
    var remaining: Int { data.count - offset }
    init(_ data: Data) { self.data = Data(data) }
    mutating func take(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func number(_ width: Int, littleEndian: Bool = false) -> Int? {
        guard (1...5).contains(width), let bytes = take(width) else { return nil }
        return (littleEndian ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << 8) | Int($1) }
    }
    mutating func field(_ width: Int, littleEndian: Bool = false) -> Data? {
        guard let size = number(width, littleEndian: littleEndian) else { return nil }
        return take(size)
    }
}
