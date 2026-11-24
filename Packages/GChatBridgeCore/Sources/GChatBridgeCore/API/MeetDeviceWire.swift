import Foundation

/// Device registration and explicit join/leave. Capabilities are supplied by
/// the implementation, never copied from a captured browser's capability set.
public enum MeetDeviceWire {
    public enum Role: UInt64, Sendable {
        case host = 1, participant = 3, cohost = 5
    }

    public struct Device: Sendable, Equatable {
        public let name: String
        public let joinState: UInt64
        public let isDeleted: Bool
        public let primaryDevice: String?
        public let captureType: UInt64
        public let displayName: String?
        public let transfer: UInt64
        public let acknowledgements: [Acknowledgement]
        public let captionLanguages: MeetCaptionWire.Languages?
        public let role: Role?
        public let audioMuteRequester: String?
        public let finalStateReason: UInt64?
        public let canRemoveParticipants: Bool
        public let knockWarningReason: UInt64?
        public let supportsWaitingRoom: Bool
        public let meetingUserID: String?
        public let canUseContinuousChat: Bool
        public let canPinForEveryone: Bool
        public let canMessageWaitingRoom: Bool
        public let isPinnedForEveryone: Bool?
        public let calendarGuestAliases: [String]
        public let isAnonymous: Bool

        public var wasRemoved: Bool {
            joinState == 7 && finalStateReason == 0
        }

        public var wasSentToWaitingRoom: Bool {
            joinState == 7 && finalStateReason == 9
        }

        public var hasHostRole: Bool {
            role == .host || role == .cohost
        }

        public var isPresentation: Bool {
            primaryDevice != nil || [2, 3, 4, 5].contains(captureType)
        }

        init(
            name: String,
            joinState: UInt64,
            isDeleted: Bool,
            primaryDevice: String? = nil,
            captureType: UInt64 = 0, displayName: String? = nil, transfer: UInt64 = 0,
            acknowledgements: [Acknowledgement] = [], captionLanguages: MeetCaptionWire.Languages? = nil,
            role: Role? = nil, audioMuteRequester: String? = nil, finalStateReason: UInt64? = 0,
            canRemoveParticipants: Bool = false, knockWarningReason: UInt64? = nil,
            supportsWaitingRoom: Bool = false, meetingUserID: String? = nil,
            canUseContinuousChat: Bool = false, canPinForEveryone: Bool = false,
            canMessageWaitingRoom: Bool = false,
            isPinnedForEveryone: Bool? = nil, calendarGuestAliases: [String] = [], isAnonymous: Bool = false
        ) {
            self.name = name; self.joinState = joinState; self.isDeleted = isDeleted
            self.primaryDevice = primaryDevice; self.captureType = captureType
            self.displayName = displayName
            self.transfer = transfer
            self.acknowledgements = acknowledgements
            self.captionLanguages = captionLanguages
            self.role = role
            self.audioMuteRequester = audioMuteRequester
            self.finalStateReason = finalStateReason
            self.canRemoveParticipants = canRemoveParticipants
            self.knockWarningReason = knockWarningReason
            self.supportsWaitingRoom = supportsWaitingRoom
            self.meetingUserID = meetingUserID
            self.canUseContinuousChat = canUseContinuousChat
            self.canPinForEveryone = canPinForEveryone
            self.canMessageWaitingRoom = canMessageWaitingRoom
            self.isPinnedForEveryone = isPinnedForEveryone
            self.calendarGuestAliases = calendarGuestAliases
            self.isAnonymous = isAnonymous
        }
    }

    /// The web source's request extension specifies client RPC semantics.
    static let clientExtension = Data([0x0A, 0x02, 0x08, 0x03]).base64EncodedString()

    public static func create(
        space: String, mediaSession: String, incomingInvitation: MeetIncomingInvitation? = nil,
        supportsWaitingRoom: Bool = false
    ) throws -> Data {
        guard validSpace(space), validMediaSession(mediaSession) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        // JOINING=2, audio/video capture mode=1, normal participation=1.
        var device = MeetProto.number(4, 2) + MeetProto.string(22, cloudID(mediaSession))
            + MeetProto.number(25, 1) + MeetProto.number(38, 1)
        if supportsWaitingRoom {
            device += MeetProto.bytes(39, Data([22]))
        }
        var body = MeetProto.string(1, space) + MeetProto.bytes(2, device)
        if let incomingInvitation {
            body += MeetProto.string(4, incomingInvitation.id)
            if let clientID = incomingInvitation.clientID {
                body += MeetProto.string(5, clientID)
            }
        }
        return body
    }

    public static func join(
        device: String, mediaSession: String, presentation: Bool = false, joinAlongside: Bool = false
    ) throws -> Data {
        guard validDevice(device), validMediaSession(mediaSession) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let value = MeetProto.string(1, device) + MeetProto.number(4, 1)
            + MeetProto.string(22, cloudID(mediaSession)) + MeetProto
            .number(25, presentation ? 2 : 1) + MeetProto.number(
                38,
                1
            )
        var paths = ["cloud_session_id", "join_state", "media_capture_type", "participation_mode"]
        // Clear the pending transfer choice exactly as native Join here too:
        // mask transfer, with field54 omitted (its default0), never TRANSFER1.
        if joinAlongside, !presentation {
            paths.append("transfer")
        }
        let mask = paths.reduce(into: Data()) { $0 += MeetProto.string(1, $1) }
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, mask)
    }

    /// The secondary credential request names the meeting space, even though
    /// the RPC belongs to MeetingDeviceService. Device names are invalid here.
    public static func secondaryTokenRequest(space: String) throws -> Data {
        guard validSpace(space) else { throw MeetCallWire.WireError.invalidIdentifier }
        return MeetProto.string(1, space)
    }

    public static func secondaryToken(from body: Data) throws -> String {
        let value = try MeetProto.text(1, MeetProto.decode(body))
        var token = MeetMeetingToken()
        token.absorb(value)
        guard token.value == value else { throw MeetCallWire.WireError.malformedResponse }
        return value
    }

    public static func leave(device: String) throws -> Data {
        guard validDevice(device) else { throw MeetCallWire.WireError.invalidIdentifier }
        let value = MeetProto.string(1, device) + MeetProto.number(4, 6)
        return MeetProto.bytes(1, value) + MeetProto.bytes(2, MeetProto.string(1, "join_state"))
    }

    public static func changeRole(device: String, cohost: Bool) throws -> Data {
        guard validDevice(device) else { throw MeetCallWire.WireError.invalidIdentifier }
        let role: Role = cohost ? .cohost : .participant
        return MeetProto.string(1, device) + MeetProto.number(2, role.rawValue)
    }

    static func confirmRoleChange(_ body: Data, space: String, target: String, cohost: Bool) throws {
        let devices = try affectedDevices(from: body, in: space)
        if devices.isEmpty {
            return
        } // A fresh collection must still confirm the changed role.
        guard let addressed = devices.first(where: { $0.name == target }),
              addressed.role == (cohost ? .cohost : .participant) else {
            throw MeetCallWire.WireError.malformedResponse
        }
    }

    static func affectedDevices(from body: Data, in space: String) throws -> [Device] {
        let data = try MeetProto.decode(body)
        let fields = ProtoFieldScan.fields(in: data).fields.filter { $0.number == 1 }
        let entries = ProtoFieldScan.payloads(ofField: 1, in: data)
        guard entries.count == fields.count, entries.count <= 256 else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let devices = try entries.map { try devicePayload($0, in: space) }
        guard Set(devices.map(\.name)).count == devices.count else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return devices
    }

    /// The RPC returns MeetingDevice directly, not a wrapper around field 1.
    public static func device(from body: Data, in space: String) throws -> Device {
        try devicePayload(MeetProto.decode(body), in: space, includeAcknowledgements: true)
    }

    static func devicePayload(
        _ data: Data, in space: String, includeAcknowledgements: Bool = false
    ) throws -> Device {
        let name = try MeetProto.text(1, data)
        guard validSpace(space), validDevice(name), name.hasPrefix(space + "/devices/") else {
            throw MeetCallWire.WireError.malformedResponse
        }
        let fields = ProtoFieldScan.fields(in: data).fields
        let deleted = try fields.contains(where: { $0.number == 9 }) ? MeetProto.value(9, data) : 0
        guard deleted <= 1 else { throw MeetCallWire.WireError.malformedResponse }
        let state = try fields.contains(where: { $0.number == 4 }) ? MeetProto.value(4, data) : 0
        let primary = try primaryDevice(in: data, name: name, space: space)
        let capture = try fields.contains(where: { $0.number == 25 }) ? MeetProto.value(25, data) : 0
        let transfer = try fields.contains(where: { $0.number == 54 }) ? MeetProto.value(54, data) : 0
        let displayName: String?
        if fields.contains(where: { $0.number == 2 }) {
            let text = try MeetProto.text(2, data)
            guard text.utf8.count <= 1024 else { throw MeetCallWire.WireError.malformedResponse }
            displayName = text.isEmpty ? nil : text
        } else {
            displayName = nil
        }
        return try Device(
            name: name,
            joinState: state,
            isDeleted: deleted == 1,
            primaryDevice: primary,
            captureType: capture, displayName: displayName, transfer: transfer,
            acknowledgements: includeAcknowledgements ? acknowledgementRequirements(in: data) : [],
            captionLanguages: fields.contains { [31, 33, 48].contains($0.number) }
                ? try? MeetCaptionWire.languages(in: data, live: 31, alternate: 48, pairs: 33) : nil,
            role: (try? MeetProto.value(46, data)).flatMap(Role.init(rawValue:)),
            audioMuteRequester: audioMuteRequester(in: data, space: space),
            finalStateReason: fields.contains { $0.number == 28 } ? try? MeetProto.value(28, data) : 0,
            canRemoveParticipants: hasDeviceEnum(1, field: 13, in: data, fields: fields),
            knockWarningReason: try? MeetProto.value(36, data),
            supportsWaitingRoom: hasDeviceEnum(22, field: 39, in: data, fields: fields),
            meetingUserID: moderationUserID(in: data),
            canUseContinuousChat: (try? MeetProto.value(64, data)) == 1,
            canPinForEveryone: hasDeviceEnum(82, field: 13, in: data, fields: fields),
            canMessageWaitingRoom: hasDeviceEnum(113, field: 13, in: data, fields: fields),
            isPinnedForEveryone: pinnedForEveryone(in: data),
            calendarGuestAliases: MeetAgendaGuestWire.aliases(data),
            isAnonymous: fields.contains { $0.number == 15 } && (try? MeetProto.value(15, data)) != 0
        )
    }

    private static func primaryDevice(in data: Data, name: String, space: String) throws -> String? {
        guard MeetActivityCollections.has(21, data) else { return nil }
        let value = try MeetProto.text(21, data)
        guard validDevice(value), value.hasPrefix(space + "/devices/"), value != name else {
            throw MeetCallWire.WireError.malformedResponse
        }
        return value
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

    static func validDevice(_ value: String) -> Bool {
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
