import Foundation

/// Full, versioned device and invitation collections. Data-channel messages
/// invalidate these snapshots; partial pushes never masquerade as full lists.
public enum MeetCallCollectionsWire {
    public struct Devices: Sendable {
        public let version: UInt64
        public let values: [MeetDeviceWire.Device]
    }

    public struct Invitation: Sendable {
        public let id: String
        /// Raw MeetingInvite status field6. Unknown values are not terminal.
        public let status: UInt64
    }

    public struct Invitations: Sendable {
        public let version: UInt64
        public let values: [Invitation]
        public var ids: Set<String> {
            Set(values.map(\.id))
        }
    }

    public struct Snapshot: Sendable {
        public let devices: Devices?
        public let invitations: Invitations?
    }

    public static func sync(space: String) throws -> Data {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        // An absent version requests FULL, matching the web collection helpers.
        return MeetProto.string(1, space) + MeetProto.bytes(3, Data()) + MeetProto.bytes(12, Data())
    }

    public static func snapshot(from body: Data, in space: String) throws -> Snapshot {
        let data = try MeetProto.decode(body)
        let devices: Devices?
        if let full = try fullCollection(2, data) {
            let entries = try values(full)
            let decoded = try entries.map { try MeetDeviceWire.devicePayload($0, in: space) }
            guard Set(decoded.map(\.name)).count == decoded.count else {
                throw MeetCallWire.WireError.malformedResponse
            }
            devices = try Devices(version: version(full), values: decoded)
        } else {
            devices = nil
        }
        let invitations: Invitations?
        if let full = try fullCollection(11, data) {
            let decoded = try values(full).map { entry in
                let id = try MeetProto.text(1, entry)
                _ = try MeetIncomingInvitation(id: id, clientID: nil)
                let status = try ProtoFieldScan.fields(in: entry).fields.contains { $0.number == 6 }
                    ? MeetProto.value(6, entry) : 0
                guard status <= UInt64(Int32.max) else { throw MeetCallWire.WireError.malformedResponse }
                return Invitation(id: id, status: status)
            }
            guard Set(decoded.map(\.id)).count == decoded.count else {
                throw MeetCallWire.WireError.malformedResponse
            }
            invitations = try Invitations(version: version(full), values: decoded)
        } else {
            invitations = nil
        }
        return Snapshot(devices: devices, invitations: invitations)
    }

    private static func fullCollection(_ field: Int, _ data: Data) throws -> Data? {
        guard ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == field })
        else { return nil }
        let wrapper = try MeetProto.payload(field, data)
        try MeetProto.validate(wrapper)
        let variants = ProtoFieldScan.fields(in: wrapper).fields.filter { [1, 2].contains($0.number) }
        guard variants.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        guard let variant = variants.first else { return nil }
        if variant.number == 1 {
            _ = try MeetProto.payload(1, wrapper)
            return nil
        }
        return try MeetProto.payload(2, wrapper)
    }

    private static func version(_ full: Data) throws -> UInt64 {
        let version = try MeetProto.value(1, MeetProto.payload(1, full))
        guard version <= UInt64(Int64.max) else { throw MeetCallWire.WireError.malformedResponse }
        return version
    }

    private static func values(_ full: Data) throws -> [Data] {
        try MeetProto.validate(full)
        let fields = ProtoFieldScan.fields(in: full).fields.filter { $0.number == 2 }
        let values = ProtoFieldScan.payloads(ofField: 2, in: full)
        guard fields.count == values.count, values.count <= 256 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        for value in values {
            try MeetProto.validate(value)
        }
        return values
    }
}
