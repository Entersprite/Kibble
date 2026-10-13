import Foundation

/// Internal protobuf primitives for the separate Meet protocol. No payload is logged.
enum MeetProto {
    static func number(_ field: UInt64, _ value: UInt64) -> Data {
        unsigned(field << 3) + unsigned(value)
    }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        unsigned(field << 3 | 2) + unsigned(UInt64(value.count)) + value
    }

    static func string(_ field: UInt64, _ value: String) -> Data {
        bytes(field, Data(value.utf8))
    }

    static func unsigned(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 128 {
            data.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }

    static func decode(_ body: Data) throws -> Data {
        guard body.count <= 1_000_000,
              let text = String(data: body, encoding: .utf8),
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw MeetCallWire.WireError.malformedResponse }
        try validate(data)
        return data
    }

    static func validate(_ data: Data) throws {
        guard !ProtoFieldScan.fields(in: data).truncated else {
            throw MeetCallWire.WireError.malformedResponse
        }
    }

    static func payload(_ field: Int, _ data: Data) throws -> Data {
        try validate(data)
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == field }
        let values = ProtoFieldScan.payloads(ofField: field, in: data)
        guard fields.count == 1, values.count == 1 else { throw MeetCallWire.WireError.malformedResponse }
        return values[0]
    }

    static func text(_ field: Int, _ data: Data) throws -> String {
        let bytes = try payload(field, data)
        guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty,
              !text.contains("\r"), !text.contains("\n"), !text.contains("\0")
        else { throw MeetCallWire.WireError.malformedResponse }
        return text
    }

    static func value(_ field: Int, _ data: Data) throws -> UInt64 {
        try validate(data)
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == field }
        let values = ProtoFieldScan.varintValues(ofField: field, in: data)
        guard fields.count == 1, values.count == 1 else { throw MeetCallWire.WireError.malformedResponse }
        return values[0]
    }
}
