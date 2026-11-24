import Foundation
import LocalBridgeBackend
import zlib

/// One binary GZIP member per negotiated activity frame.
enum NativeActivityGzip {
    static let maximumInboundBytes = 256_000
    private static let maximumOutboundBytes = 64000
    private static let windowBits: Int32 = 15 + 16

    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumOutboundBytes else {
            throw CallMediaError.connectionFailed
        }
        var stream = z_stream()
        let initialized = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initialized == Z_OK else { throw CallMediaError.connectionFailed }
        defer { deflateEnd(&stream) }
        let capacity = min(Int(deflateBound(&stream, uLong(payload.count))), maximumOutboundBytes)
        return try transcode(payload, stream: &stream, capacity: capacity) { deflate($0, Z_FINISH) }
    }

    static func decode(_ frame: Data) throws -> Data {
        // The unsigned little-endian ISIZE trailer is an allocation hint only.
        // zlib validates the checksum, uncompressed size and member boundary.
        guard (18 ... 1_000_000).contains(frame.count) else { throw CallMediaError.connectionFailed }
        let size = frame.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard (1 ... maximumInboundBytes).contains(size) else { throw CallMediaError.connectionFailed }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw CallMediaError.connectionFailed }
        defer { inflateEnd(&stream) }
        let decoded = try transcode(frame, stream: &stream, capacity: size + 1) { inflate($0, Z_FINISH) }
        guard decoded.count == size else { throw CallMediaError.connectionFailed }
        return decoded
    }

    private static func transcode(
        _ input: Data, stream: inout z_stream, capacity: Int,
        _ operation: (UnsafeMutablePointer<z_stream>) -> Int32
    ) throws -> Data {
        var output = Data(count: capacity)
        let status = input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                defer { stream.next_in = nil; stream.next_out = nil }
                return operation(&stream)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw CallMediaError.connectionFailed }
        output.count = Int(stream.total_out)
        return output
    }
}
