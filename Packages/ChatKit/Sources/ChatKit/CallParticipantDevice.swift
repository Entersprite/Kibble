import Foundation

public enum CallParticipantRole: String, Codable, Sendable {
    case host, cohost, participant
}

/// Ephemeral, call-local device identity. It is never a provider resource or a
/// fabricated directory member. A presentation can name its parent device.
public struct CallParticipantDevice: Codable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String?
    public let parentID: UUID?
    public let isPresentation: Bool
    public let isLocal: Bool
    public var microphoneMuted: Bool?
    public var handRaised: Bool?
    public var handRaisedAt: Date?
    public let isSpeaking: Bool?
    public var role: CallParticipantRole?
    public let canSendToWaitingRoom: Bool?
    public let canBlockInMeeting: Bool?
    public var isPinnedForEveryone: Bool?

    public init(
        id: UUID, displayName: String? = nil, parentID: UUID? = nil,
        isPresentation: Bool = false, isLocal: Bool = false, microphoneMuted: Bool? = nil,
        handRaised: Bool? = nil, isSpeaking: Bool? = nil, role: CallParticipantRole? = nil,
        canSendToWaitingRoom: Bool? = nil, canBlockInMeeting: Bool? = nil, isPinnedForEveryone: Bool? = nil,
        handRaisedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.parentID = parentID
        self.isPresentation = isPresentation
        self.isLocal = isLocal
        self.microphoneMuted = microphoneMuted
        self.handRaised = handRaised
        self.handRaisedAt = handRaisedAt
        self.isSpeaking = isSpeaking
        self.role = role
        self.canSendToWaitingRoom = canSendToWaitingRoom
        self.canBlockInMeeting = canBlockInMeeting
        self.isPinnedForEveryone = isPinnedForEveryone
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, parentID, isPresentation, isLocal, microphoneMuted, handRaised, isSpeaking, role
        case canSendToWaitingRoom, canBlockInMeeting, isPinnedForEveryone, handRaisedAt
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: fields.decode(UUID.self, forKey: .id),
            displayName: fields.decodeIfPresent(String.self, forKey: .displayName),
            parentID: fields.decodeIfPresent(UUID.self, forKey: .parentID),
            isPresentation: fields.decodeIfPresent(Bool.self, forKey: .isPresentation) ?? false,
            isLocal: fields.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false,
            microphoneMuted: try? fields.decodeIfPresent(Bool.self, forKey: .microphoneMuted),
            handRaised: try? fields.decodeIfPresent(Bool.self, forKey: .handRaised),
            isSpeaking: try? fields.decodeIfPresent(Bool.self, forKey: .isSpeaking),
            role: try? fields.decodeIfPresent(CallParticipantRole.self, forKey: .role),
            canSendToWaitingRoom: try? fields.decodeIfPresent(Bool.self, forKey: .canSendToWaitingRoom),
            canBlockInMeeting: try? fields.decodeIfPresent(Bool.self, forKey: .canBlockInMeeting),
            isPinnedForEveryone: try? fields.decodeIfPresent(Bool.self, forKey: .isPinnedForEveryone),
            handRaisedAt: try? fields.decodeIfPresent(Date.self, forKey: .handRaisedAt)
        )
    }
}
