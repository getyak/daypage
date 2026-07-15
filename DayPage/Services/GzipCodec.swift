import Foundation
import zlib

// MARK: - GzipCodec

/// Minimal gzip compress/decompress over the SDK's bundled zlib.
///
/// The Doubao streaming ASR protocol gzips every frame payload in both
/// directions, and Foundation ships no gzip primitive (`Compression`'s
/// `zlib` algorithm emits a raw deflate stream — no gzip header/trailer — so
/// it is not interchangeable). Rather than take a third-party dependency for
/// two function calls, we drive zlib directly: `deflateInit2` / `inflateInit2`
/// with `windowBits + 16` selects the gzip wrapper.
enum GzipCodec {

    enum CodecError: Error {
        case compressFailed(code: Int32)
        case decompressFailed(code: Int32)
    }

    /// zlib's `windowBits` for a 32K window; `+16` requests the gzip wrapper
    /// instead of the zlib one, `+32` (decompress only) auto-detects either.
    private static let gzipWindowBits: Int32 = 15 + 16
    private static let autoDetectWindowBits: Int32 = 15 + 32

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            gzipWindowBits,
            8,                      // memLevel: zlib's default
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw CodecError.compressFailed(code: status) }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32_768
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            repeat {
                try buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw CodecError.compressFailed(code: status)
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0, let addr = out.baseAddress {
                        output.append(addr, count: produced)
                    }
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }

        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            autoDetectWindowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw CodecError.decompressFailed(code: status) }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32_768
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            repeat {
                try buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw CodecError.decompressFailed(code: status)
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0, let addr = out.baseAddress {
                        output.append(addr, count: produced)
                    }
                }
                // Z_BUF_ERROR with no input left means the stream is truncated;
                // bail rather than spin forever on an empty read.
                if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
            } while status != Z_STREAM_END
        }
        return output
    }
}
