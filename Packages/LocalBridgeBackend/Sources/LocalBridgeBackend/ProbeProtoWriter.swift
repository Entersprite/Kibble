import Foundation

/// A protobuf writer just big enough for the thread probe's requests, whose fields no vendored proto
/// names (`findings.md` §64). Field numbers in, bytes out; it never reads.
struct ProbeProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        append(varint: value)
    }

    mutating func int64(_ field: Int, _ value: Int64) {
        varint(field, UInt64(bitPattern: value))
    }

    /// Written even when false: these fields are proto2 `optional`, so presence is part of the value.
    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ payload: Data) {
        key(field, wireType: 2)
        append(varint: UInt64(payload.count))
        data.append(payload)
    }

    mutating func message(_ field: Int, _ build: (inout ProbeProtoWriter) -> Void) {
        var inner = ProbeProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        append(varint: UInt64(field) << 3 | wireType)
    }

    private mutating func append(varint value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }
}
