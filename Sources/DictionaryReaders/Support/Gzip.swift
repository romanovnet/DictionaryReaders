// SPDX-License-Identifier: MIT
import Foundation
import Compression

/// RFC 1952 framing and platform-backed raw DEFLATE decompression.
/// No compression implementation is vendored. Checksums are not validated.
enum Gzip {
    static func hasMagic(_ data: Data) -> Bool {
        data.starts(with: [0x1F, 0x8B])
    }

    /// Decompress a complete gzip stream. `limit`, when set, stops once at least
    /// that many output bytes have been produced (returning a prefix) — used for
    /// cheap content sniffing without inflating the whole file.
    static func decompress(_ data: Data, limit: Int? = nil) throws -> Data {
        guard let start = deflateStart(in: data) else { throw GzipError.malformedHeader }
        let payload = data.subdata(in: start..<data.endIndex)
        return try inflate(payload, limit: limit)
    }

    /// Inflate a complete **zlib** stream (RFC 1950: 2-byte header + DEFLATE +
    /// Adler-32). Strips the 2-byte header and runs the full streaming inflate
    /// (to stream end), used by Apple Dictionary `Body.data` sections.
    static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        return try? inflate(data.dropFirst(2), limit: nil)
    }

    /// Parse the gzip header and return the index where the raw DEFLATE body
    /// begins. Header = fixed 10 bytes + optional FEXTRA/FNAME/FCOMMENT/FHCRC
    /// fields selected by the flag byte.
    private static func deflateStart(in data: Data) -> Int? {
        let base = data.startIndex
        let end = data.endIndex
        guard data.count >= 10,
              data[base] == 0x1F, data[base + 1] == 0x8B,
              data[base + 2] == 0x08                          // CM = DEFLATE
        else { return nil }

        let flg = data[base + 3]
        var p = base + 10

        if flg & 0x04 != 0 {                                   // FEXTRA
            guard p + 2 <= end else { return nil }
            let xlen = Int(data[p]) | (Int(data[p + 1]) << 8)
            p += 2 + xlen
        }
        if flg & 0x08 != 0 {                                   // FNAME (NUL-terminated)
            while p < end, data[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x10 != 0 {                                   // FCOMMENT (NUL-terminated)
            while p < end, data[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 }                          // FHCRC

        return p <= end ? p : nil
    }

    private static func inflate(_ payload: Data, limit: Int?) throws -> Data {
        guard !payload.isEmpty else { throw GzipError.decompressionFailed }

        let bufferSize = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        // `compression_stream` is a C struct with no zeroing init; the pointer
        // fields are placeholders that `compression_stream_init` and the loop
        // below overwrite before any read.
        var stream = compression_stream(
            dst_ptr: dst, dst_size: bufferSize,
            src_ptr: UnsafePointer(dst), src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw GzipError.decompressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        let result: Data? = payload.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = src
            stream.src_size = raw.count
            stream.dst_ptr = dst
            stream.dst_size = bufferSize

            while true {
                let status = compression_stream_process(&stream, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 { output.append(dst, count: produced) }
                    stream.dst_ptr = dst
                    stream.dst_size = bufferSize
                    if status == COMPRESSION_STATUS_END { return output }
                    if let limit, output.count >= limit { return output }
                default:
                    return nil
                }
            }
        }

        guard let result else { throw GzipError.decompressionFailed }
        return result
    }

    /// Inflate one **raw DEFLATE segment** (no gzip/zlib wrapper) whose
    /// decompressed size is at most `maxSize`. Used for dictzip random access:
    /// each chunk ends at a `Z_FULL_FLUSH` boundary (byte-aligned, dictionary
    /// reset) rather than a stream end, so we decode *without* the FINALIZE flag
    /// — the decoder consumes the chunk's blocks and stops when input runs out.
    /// Returns the bytes produced (a non-final chunk yields exactly its chunk
    /// length; the last chunk yields the remainder), or nil on error.
    static func inflateChunk(_ payload: Data, maxSize: Int) -> Data? {
        guard !payload.isEmpty, maxSize > 0 else { return nil }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: maxSize)
        defer { dst.deallocate() }

        var stream = compression_stream(
            dst_ptr: dst, dst_size: maxSize,
            src_ptr: UnsafePointer(dst), src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }

        return payload.withUnsafeBytes { raw -> Data? in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = src
            stream.src_size = raw.count
            stream.dst_ptr = dst
            stream.dst_size = maxSize
            let status = compression_stream_process(&stream, 0)   // no FINALIZE
            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else { return nil }
            let produced = maxSize - stream.dst_size
            guard produced > 0 else { return nil }
            return Data(bytes: dst, count: produced)
        }
    }
}

enum GzipError: Error, Equatable {
    case malformedHeader
    case decompressionFailed
}
