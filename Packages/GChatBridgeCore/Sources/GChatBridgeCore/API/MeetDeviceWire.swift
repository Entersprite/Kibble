import Foundation

/// Device registration and explicit join/leave. Capabilities are supplied by
/// the implementation, never copied from a captured browser's capability set.
public enum MeetDeviceWire {
    public struct Device: Sendable, Equatable {
        public let name: String
        public let joinState: UInt64
        public let isDeleted: Bool
    }

    /// The web source's request extension specifies client RPC semantics.
    static let clientExtension = Data([0x0A, 0x02, 0x08, 0x03]).base64EncodedString()

    public static func create(
        space: String, mediaSession: String, incomingInvitation: MeetIncomingInvitation? = nil
    ) throws -> Data {
        guard validSpace(space), validMediaSession(mediaSession) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        // JOINING=2, audio/video capture mode=1, normal participation=1.
        // Omit unsupported device and viewer capability enums (fields 18/39).
        let device = MeetProto.number(4, 2) + MeetProto.string(22, cloudID(mediaSession))
            + MeetProto.number(25, 1) + MeetProto.number(38, 1)
        var body = MeetProto.string(1, space) + MeetProto.bytes(2, device)
        if let incomingInvitation {
            body += MeetProto.string(4, incomingInvitation.id)
            if let clientID = incomingInvitation.clientID {
                body += MeetProto.string(5, clientID)
            }
        }
        return body
    }

    public static func join(device: String, mediaSession: String) throws -> Data {
        guard validDevice(device), validMediaSession(mediaSession) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let value = MeetProto.string(1, device) + MeetProto.number(4, 1)
            + MeetProto.string(22, cloudID(mediaSession)) + MeetProto.number(25, 1) + MeetProto.number(38, 1)
        let mask = ["cloud_session_id", "join_state", "media_capture_type", "participation_mode"]
            .reduce(into: Data()) { $0 += MeetProto.string(1, $1) }
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, mask)
    }

    public static func leave(device: String) throws -> Data {
        guard validDevice(device) else { throw MeetCallWire.WireError.invalidIdentifier }
        let value = MeetProto.string(1, device) + MeetProto.number(4, 6)
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, MeetProto.string(1, "join_state"))
    }

    /// The RPC returns MeetingDevice directly, not a wrapper around field 1.
    public static func device(from body: Data, in space: String) throws -> Device {
        try devicePayload(MeetProto.decode(body), in: space)
    }

    static func devicePayload(_ data: Data, in space: String) throws -> Device {
        let name = try MeetProto.text(1, data)
        guard validSpace(space), validDevice(name), name.hasPrefix(space + "/devices/") else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let deleted: Bool
        if ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == 9 }) {
            let value = try MeetProto.value(9, data)
            guard value <= 1 else { throw MeetCallWire.WireError.malformedResponse }
            deleted = value == 1
        } else {
            deleted = false
        }
        let state = try ProtoFieldScan.fields(in: data).fields.contains(where: { $0.number == 4 })
            ? MeetProto.value(4, data) : 0
        return Device(name: name, joinState: state, isDeleted: deleted)
    }

    static func validSpace(_ value: String) -> Bool {
        resource(value, prefix: "spaces/")
    }

    static func validMediaSession(_ value: String) -> Bool {
        resource(value, prefix: "mediasessions/")
    }

    private static func cloudID(_ name: String) -> String {
        String(name.dropFirst("mediasessions/".count))
    }

    private static func validDevice(_ value: String) -> Bool {
        let parts = value.components(separatedBy: "/devices/")
        return parts.count == 2 && validSpace(parts[0]) && identifier(parts[1])
    }

    private static func resource(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && identifier(String(value.dropFirst(prefix.count)))
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }
}
