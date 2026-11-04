import Foundation

public extension MeetDeviceWire {
    struct Acknowledgement: Sendable, Equatable {
        public let type: UInt64
        public let state: UInt64
    }

    /// The native ack RPC updates only the current device's requirement list.
    /// It has no join/transfer mutation or field mask.
    static func acknowledge(device: String, requirements: [Acknowledgement]) throws -> Data {
        guard validDevice(device), !requirements.isEmpty, requirements.count <= 32,
              Set(requirements.map(\.type)).count == requirements.count,
              requirements.allSatisfy({ [1, 2, 3, 4, 5, 8, 9, 10].contains($0.type) && $0.state == 1 })
        else { throw MeetCallWire.WireError.invalidIdentifier }
        let value = requirements.reduce(into: MeetProto.string(1, device)) {
            $0 += MeetProto.bytes(41, MeetProto.number(1, $1.type) + MeetProto.number(2, 2))
        }
        return MeetProto.bytes(1, value)
    }

    internal static func acknowledgementRequirements(in data: Data) throws -> [Acknowledgement] {
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == 41 }
        let values = ProtoFieldScan.payloads(ofField: 41, in: data)
        guard values.count <= 32, fields.count == values.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let requirements = try values.map { value in
            guard value.count <= 4096 else { throw MeetCallWire.WireError.malformedResponse }
            try MeetProto.validate(value)
            let fields = ProtoFieldScan.fields(in: value).fields
            let type = try fields.contains { $0.number == 1 } ? MeetProto.value(1, value) : 0
            let state = try fields.contains { $0.number == 2 } ? MeetProto.value(2, value) : 0
            return Acknowledgement(type: type, state: state)
        }
        guard Set(requirements.map(\.type)).count == requirements.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return requirements
    }
}
