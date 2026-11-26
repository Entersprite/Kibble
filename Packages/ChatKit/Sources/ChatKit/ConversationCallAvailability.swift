import Foundation

/// An observed conversation-level call, separate from retained message history.
/// This value grants neither meeting admission nor control of another session.
public struct ConversationCallAvailability: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID
    public let status: ConversationCallStatus
    public let checkedAt: Date
    public let reference: String?
    public let joinURL: URL?
    public let participantsChangedAt: Date?
    /// Nil means the roster was not established, rather than nobody is present.
    public let participants: [ConversationCallParticipant]?
    public let totalParticipants: Int?

    public init(
        conversationID: Conversation.ID, status: ConversationCallStatus, checkedAt: Date,
        reference: String? = nil, joinURL: URL? = nil, participantsChangedAt: Date? = nil,
        participants: [ConversationCallParticipant]? = nil, totalParticipants: Int? = nil
    ) {
        self.conversationID = conversationID
        self.status = status
        self.checkedAt = checkedAt
        self.reference = reference
        self.joinURL = joinURL
        self.participantsChangedAt = participantsChangedAt
        self.participants = participants
        self.totalParticipants = totalParticipants
    }

    /// Callers choose a bounded age and supply their clock. Clock reversal and
    /// an invalid interval cannot turn an old observation into a current one.
    public func isFresh(at date: Date, maximumAge: TimeInterval) -> Bool {
        let age = date.timeIntervalSince(checkedAt)
        return maximumAge.isFinite && maximumAge >= 0 && age.isFinite && age >= 0 && age <= maximumAge
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID, status, checkedAt, reference, joinURL
        case participantsChangedAt, participants, totalParticipants
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            conversationID: values.decode(Conversation.ID.self, forKey: .conversationID),
            status: values.decode(ConversationCallStatus.self, forKey: .status),
            checkedAt: values.decodeWire(Date.self, forKey: .checkedAt),
            reference: values.decodeIfPresent(String.self, forKey: .reference),
            joinURL: values.decodeIfPresent(URL.self, forKey: .joinURL),
            participantsChangedAt: values.decodeWireIfPresent(Date.self, forKey: .participantsChangedAt),
            participants: values.decodeIfPresent([ConversationCallParticipant].self, forKey: .participants),
            totalParticipants: values.decodeIfPresent(Int.self, forKey: .totalParticipants)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(status, forKey: .status)
        try values.encodeWire(checkedAt, forKey: .checkedAt)
        try values.encodeIfPresent(reference, forKey: .reference)
        try values.encodeIfPresent(joinURL, forKey: .joinURL)
        try values.encodeWireIfPresent(participantsChangedAt, forKey: .participantsChangedAt)
        try values.encodeIfPresent(participants, forKey: .participants)
        try values.encodeIfPresent(totalParticipants, forKey: .totalParticipants)
    }
}

public enum ConversationCallStatus: Codable, Hashable, Sendable {
    case active, inactive
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try WireString.decode(from: decoder) {
        case "active": self = .active
        case "inactive": self = .inactive
        case let raw: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: String = switch self {
        case .active: "active"
        case .inactive: "inactive"
        case let .unknown(raw): raw
        }
        try WireString.encode(value, to: encoder)
    }
}

/// Identified people and anonymous participants remain distinct. A missing
/// member ID must never be replaced with a fabricated account identity.
public struct ConversationCallParticipant: Codable, Hashable, Sendable {
    public let memberID: Member.ID?
    public let displayName: String?

    public init(memberID: Member.ID? = nil, displayName: String? = nil) {
        self.memberID = memberID
        self.displayName = displayName
    }
}

public protocol CallDiscoveryBackend: Sendable {
    func callAvailability(in conversationID: Conversation.ID) async throws -> ConversationCallAvailability
}
