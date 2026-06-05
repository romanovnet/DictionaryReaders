// SPDX-License-Identifier: MIT
import Foundation

struct AppleProps: Sendable {
    let keyTextCompressed: Bool
    let bodyHasSections: Bool
    let fixedFieldByteLen: Int
}

/// Heap decoding and address records are separate from dictionary presentation.
/// All offsets and lengths are validated before slices are formed.
enum AppleHeap {
    static func integer(_ data: Data, _ position: Int, _ width: Int = 4) -> Int? {
        guard position >= 0, width > 0, position <= data.count, width <= data.count - position else { return nil }
        return data[position..<position + width].reversed().reduce(0) { ($0 << 8) | Int($1) }
    }
    static func range(_ data: Data) -> Range<Int>? {
        guard let end = integer(data, 64), let first = integer(data, 68), let second = integer(data, 72) else { return nil }
        let start = first == 0 && second == 0xffffffff ? 32 : 4
        guard end > start, end <= data.count - 64 else { return nil }
        return start..<end
    }
    static func bodySection(_ data: Data, address: Int, compressed: Bool) -> Data? {
        let start = address + 64
        guard let length = integer(data, start + 4), length >= (compressed ? 4 : 0) else { return nil }
        let payload = start + (compressed ? 12 : 8), count = length - (compressed ? 4 : 0)
        guard payload <= data.count, count <= data.count - payload else { return nil }
        let bytes = data.subdata(in: payload..<payload + count)
        return compressed ? Gzip.inflateZlib(bytes) : bytes
    }
    static func keywords(_ file: Data, compressed: Bool) -> Data? {
        guard let span = range(file) else { return nil }
        if !compressed { return file.subdata(in: 64 + span.lowerBound..<64 + span.upperBound) }
        guard let allocation = integer(file, 64 + span.lowerBound), allocation > 0 else { return nil }
        var offset = 68 + span.lowerBound
        var output = Data()
        while offset < 64 + span.upperBound {
            guard let packed = integer(file, offset), let unpacked = integer(file, offset + 4) else { return nil }
            if packed == 0 && unpacked == 0 { break }
            let limit = 64 + span.upperBound
            guard packed >= 4, offset + 8 <= limit, packed - 4 <= limit - offset - 8,
                  let section = Gzip.inflateZlib(file.subdata(in: offset + 8..<offset + packed + 4)),
                  section.count == unpacked else { return nil }
            output.append(section)
            // Each group occupies whole allocation units, including when its
            // compressed payload exceeds one unit.
            let occupied = packed + 4
            let units = (occupied - 1) / allocation + 1
            guard units <= (limit - offset) / allocation else { return nil }
            offset += units * allocation
        }
        return output
    }
}

enum AppleKeyText {
    struct Result {
        var addresses: [(sectionOffset: Int, chunkOffset: Int)] = []
        var keywordsByAddress: [[String]] = []
    }
    private struct Address: Hashable { let section: Int; let chunk: Int }
    static func index(at url: URL, props: AppleProps) -> Result? {
        guard let file = try? Data(contentsOf: url, options: .mappedIfSafe),
              let bytes = AppleHeap.keywords(file, compressed: props.keyTextCompressed) else { return nil }
        var groups: [Address: [(word: String, rank: Int, order: Int)]] = [:], order: [Address] = []
        var position = 0, sequence = 0
        while position < bytes.count {
            let headerSize = props.keyTextCompressed ? 4 : 8
            guard let jump = AppleHeap.integer(bytes, position), jump > headerSize,
                  jump <= bytes.count - position - 4,
                  let count = AppleHeap.integer(bytes, position + headerSize, 2) else { return nil }
            let end = position + jump + 4
            var cursor = ReaderBytes(bytes.subdata(in: position + headerSize + 2..<end))
            // The group header has one reserved word. Records then follow
            // consecutively; any zero words before a length are padding.
            // Confirmed at decompressed NOAD offset 786 (two records).
            guard cursor.take(2) != nil else { return nil }
            for _ in 0..<count {
                var size = 0
                repeat { guard let n = cursor.number(2, littleEndian: true) else { return nil }; size = n } while size == 0
                guard let record = cursor.take(size) else { return nil }
                var fields = ReaderBytes(record)
                let address: Address
                if props.bodyHasSections {
                    guard let chunk = fields.number(4, littleEndian: true), let section = fields.number(4, littleEndian: true) else { return nil }
                    address = Address(section: section, chunk: chunk)
                } else {
                    guard let chunk = fields.number(4, littleEndian: true) else { return nil }
                    address = Address(section: 0, chunk: chunk)
                }
                guard let fixed = fields.take(props.fixedFieldByteLen) else { return nil }
                var word = ""
                while word.isEmpty && fields.remaining > 0 {
                    guard let utf16 = fields.field(2, littleEndian: true), utf16.count.isMultiple(of: 2),
                          let decoded = String(data: utf16, encoding: .utf16LittleEndian) else { return nil }
                    word = decoded
                }
                guard !word.isEmpty else { continue }
                let flag = fixed.count == 2 ? AppleHeap.integer(fixed, 0, 2) ?? 0 : 0
                // Bits 1–4 hold priority; bit 0 is parental
                // control. Other flag bits do not erase the priority field.
                let rank = (flag >> 1) & 15
                if groups[address] == nil { order.append(address) }
                groups[address, default: []].append((word, rank, sequence)); sequence += 1
            }
            position = end
        }
        guard !order.isEmpty else { return nil }
        var result = Result()
        for address in order {
            var seen = Set<String>()
            let words = groups[address]!.sorted { $0.rank == $1.rank ? $0.order < $1.order : $0.rank > $1.rank }
                .map(\.word).filter { seen.insert($0).inserted }
            result.addresses.append((address.section, address.chunk)); result.keywordsByAddress.append(words)
        }
        return result
    }
}
