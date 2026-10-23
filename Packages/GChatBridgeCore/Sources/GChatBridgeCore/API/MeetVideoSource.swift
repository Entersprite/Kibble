import Foundation

/// One VP8 source and its optional retransmission source. Simulcast and
/// presentation streams require a separate negotiation policy.
public struct MeetVideoSource: Sendable, Hashable {
    public let primary: UInt32
    public let retransmission: UInt32?

    public init(primary: UInt32, retransmission: UInt32? = nil) throws {
        guard primary > 0, retransmission != 0, retransmission != primary else {
            throw MeetCallWire.WireError.malformedResponse
        }
        self.primary = primary
        self.retransmission = retransmission
    }

    var values: [UInt32] {
        [primary, retransmission].compactMap(\.self)
    }

    var protobuf: Data {
        var result = MeetProto.bytes(1, values.reduce(into: Data()) { $0 += MeetProto.unsigned(UInt64($1)) })
        if let retransmission {
            let group = MeetProto.string(1, "FID")
                + MeetProto.bytes(
                    2,
                    MeetProto.unsigned(UInt64(primary)) + MeetProto.unsigned(UInt64(retransmission))
                )
            result += MeetProto.bytes(2, group)
        }
        return result
    }

    static func parse(_ data: Data) throws -> Self {
        try validateSource(data)
        var values = try ProtoFieldScan.varintValues(ofField: 1, in: data).map { value -> UInt32 in
            guard let value = UInt32(exactly: value), value > 0 else {
                throw MeetCallWire.WireError.malformedResponse
            }
            return value
        }
        for packed in ProtoFieldScan.payloads(ofField: 1, in: data) {
            values += try unpack(packed)
        }
        guard (1 ... 2).contains(values.count), Set(values).count == values.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let groups = ProtoFieldScan.payloads(ofField: 2, in: data)
        if values.count == 1 {
            guard groups.isEmpty else { throw MeetCallWire.WireError.malformedResponse }
            return try Self(primary: values[0])
        }
        guard groups.count == 1, try MeetProto.text(1, groups[0]) == "FID" else {
            throw MeetCallWire.WireError.malformedResponse
        }
        var pair = try ProtoFieldScan.varintValues(ofField: 2, in: groups[0]).map { value -> UInt32 in
            guard let value = UInt32(exactly: value) else { throw MeetCallWire.WireError.malformedResponse }
            return value
        }
        for packed in ProtoFieldScan.payloads(ofField: 2, in: groups[0]) {
            pair += try unpack(packed)
        }
        guard pair.count == 2,
              Set(pair) == Set(values) else { throw MeetCallWire.WireError.malformedResponse }
        return try Self(primary: pair[0], retransmission: pair[1])
    }

    private static func validateSource(_ data: Data) throws {
        guard data.count <= 10000 else { throw MeetCallWire.WireError.malformedResponse }
        try MeetProto.validate(data)
        guard ProtoFieldScan.fields(in: data).fields.allSatisfy({
            ($0.number != 1 || [0, 2].contains($0.wireType)) && ($0.number != 2 || $0.wireType == 2)
        }) else { throw MeetCallWire.WireError.malformedResponse }
    }

    private static func unpack(_ data: Data) throws -> [UInt32] {
        var values: [UInt32] = [], value: UInt64 = 0, shift = 0
        for byte in data {
            guard shift < 35, values.count < 2 else { throw MeetCallWire.WireError.malformedResponse }
            value |= UInt64(byte & 127) << shift
            if byte < 128 {
                guard let source = UInt32(exactly: value), source > 0 else {
                    throw MeetCallWire.WireError.malformedResponse
                }
                values.append(source); value = 0; shift = 0
            } else {
                shift += 7
            }
        }
        guard shift == 0 else { throw MeetCallWire.WireError.malformedResponse }
        return values
    }
}
