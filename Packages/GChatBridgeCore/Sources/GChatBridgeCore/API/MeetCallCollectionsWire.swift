import Foundation

/// Full, versioned device and invitation collections. Data-channel messages
/// invalidate these snapshots; partial pushes never masquerade as full lists.
public enum MeetCallCollectionsWire {
    public struct Devices: Sendable {
        public let version: UInt64
        public let values: [MeetDeviceWire.Device]

        func hostAccess(for name: String) -> MeetActivityCollections.HostAccess {
            let local = values.first {
                $0.name == name && $0.joinState == 1 && !$0.isDeleted && !$0.isPresentation
            }
            return .init(
                version: version, role: local?.role,
                canRemoveParticipants: local?.canRemoveParticipants == true,
                canUseContinuousChat: local?.canUseContinuousChat == true,
                canPinForEveryone: local?.hasHostRole == true && local?.canPinForEveryone == true,
                canMessageWaitingRoom: local?.canMessageWaitingRoom == true
            )
        }
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
        public internal(set) var devices: Devices?
        public let invitations: Invitations?
        public var hands: Hands?
        public var activities: MeetActivityCollections.Snapshot?
    }

    public struct Hand: Sendable {
        public let name: String
        public let device: String
        public let raisedAt: Date?
        let isRaised: Bool
    }

    public struct Hands: Sendable {
        public let version: UInt64
        public let values: [Hand]
    }

    public static func sync(space: String) throws -> Data {
        guard MeetDeviceWire.validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        // An absent version requests FULL, matching the web collection helpers.
        return MeetActivityCollections.sync(space: space) + MeetProto.bytes(3, Data())
            + MeetProto.bytes(11, Data()) + MeetProto.bytes(12, Data())
    }

    public static func snapshot(from body: Data, in space: String) throws -> Snapshot {
        let data = try MeetProto.decode(body)
        let devices = try devices(in: data, space: space)
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
        var snapshot = Snapshot(devices: devices, invitations: invitations)
        if let full = try fullCollection(10, data) {
            let hands = try values(full).map { entry in
                let name = try MeetProto.text(1, entry)
                let device = try MeetProto.text(4, entry)
                guard name.hasPrefix(space + "/"), name.utf8.count <= 512,
                      device.hasPrefix(space + "/devices/"), device.utf8.count <= 512 else {
                    throw MeetCallWire.WireError.malformedResponse
                }
                let raised = try MeetActivityCollections.has(3, entry) ? MeetProto.value(3, entry) != 0 : true
                return Hand(
                    name: name, device: device, raisedAt: MeetProto.timestamp(2, entry), isRaised: raised
                )
            }
            guard Set(hands.map(\.name)).count == hands.count,
                  Set(hands.map(\.device)).count == hands.count
            else { throw MeetCallWire.WireError.malformedResponse }
            snapshot.hands = try Hands(version: version(full), values: hands.filter(\.isRaised))
        }
        snapshot.activities = try MeetActivityCollections.availableSnapshot(body, space: space)
        return snapshot
    }

    static func devices(in data: Data, space: String) throws -> Devices? {
        guard let full = try fullCollection(2, data) else { return nil }
        let decoded = try values(full).map { try MeetDeviceWire.devicePayload($0, in: space) }
        guard Set(decoded.map(\.name)).count == decoded.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return try Devices(version: version(full), values: decoded)
    }

    static func admissionRead(from body: Data, in space: String, name: String) throws
        -> (version: UInt64, device: MeetDeviceWire.Device?)? {
        guard MeetDeviceWire.validDevice(name), name.hasPrefix(space + "/devices/") else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        guard let full = try fullCollection(2, MeetProto.decode(body)) else { return nil }
        let revision = try version(full)
        let selected = try values(full).filter {
            ProtoFieldScan.payloads(ofField: 1, in: $0).contains(Data(name.utf8))
        }
        guard selected.count <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        let device = try selected.first.map { try MeetDeviceWire.devicePayload(
            $0,
            in: space,
            includeAcknowledgements: true
        ) }
        return (revision, device)
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

    static func version(_ full: Data) throws -> UInt64 {
        let metadata = try MeetProto.payload(1, full)
        // The native protobuf int64 getter defaults an omitted scalar to zero.
        // Keep malformed/duplicate/wrong-wire fields distinct from omission.
        let version = try MeetActivityCollections.has(1, metadata) ? MeetProto.value(1, metadata) : 0
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
