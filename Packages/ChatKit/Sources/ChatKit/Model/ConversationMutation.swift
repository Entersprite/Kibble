import Foundation

public enum ConversationMutation: Hashable, Sendable, Codable {
    case identity(name: String?, description: String?, access: ConversationAccess?)
    case addPeople([Member.ID])
    case removePerson(Member.ID)
    case setRole(Member.ID, ConversationRole)
    case join, requestJoin, acceptInvitation, declineInvitation
    /// Blocks a space the account has been invited to and has not joined.
    case block
    case approveRequest(Member.ID), rejectRequest(Member.ID)
    case leave
    case deleteSpace
    case unknown(JSONValue)

    public var action: String {
        switch self {
        case .identity: "identity"
        case .addPeople: "addPeople"
        case .removePerson: "removePerson"
        case .setRole: "setRole"
        case .join: "join"
        case .requestJoin: "requestJoin"
        case .acceptInvitation: "acceptInvitation"
        case .declineInvitation: "declineInvitation"
        case .block: "block"
        case .approveRequest: "approveRequest"
        case .rejectRequest: "rejectRequest"
        case .leave: "leave"
        case .deleteSpace: "deleteSpace"
        case .unknown: "unknown"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, description, access, members, member, role
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let type = try fields.decode(String.self, forKey: .type)
        if let action = Self.simpleActions[type] {
            self = action; return
        }
        switch type {
        case "identity": self = try .identity(
                name: fields.decodeIfPresent(String.self, forKey: .name),
                description: fields.decodeIfPresent(String.self, forKey: .description),
                access: fields.decodeIfPresent(ConversationAccess.self, forKey: .access)
            )
        case "addPeople": self = try .addPeople(fields.decode([Member.ID].self, forKey: .members))
        case "removePerson": self = try .removePerson(fields.decode(Member.ID.self, forKey: .member))
        case "setRole": self = try .setRole(
                fields.decode(Member.ID.self, forKey: .member), fields.decode(
                    ConversationRole.self,
                    forKey: .role
                )
            )
        case "approveRequest": self = try .approveRequest(fields.decode(Member.ID.self, forKey: .member))
        case "rejectRequest": self = try .rejectRequest(fields.decode(Member.ID.self, forKey: .member))
        default: self = try .unknown(JSONValue(from: decoder))
        }
    }

    private static let simpleActions: [String: Self] = [
        "leave": .leave, "join": .join, "requestJoin": .requestJoin, "acceptInvitation": .acceptInvitation,
        "declineInvitation": .declineInvitation, "deleteSpace": .deleteSpace, "block": .block
    ]

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(payload) = self {
            try payload.encode(to: encoder); return
        }
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(action, forKey: .type)
        switch self {
        case let .identity(name, description, access):
            try fields.encodeIfPresent(name, forKey: .name)
            try fields.encodeIfPresent(description, forKey: .description)
            try fields.encodeIfPresent(access, forKey: .access)
        case let .addPeople(members): try fields.encode(members, forKey: .members)
        case let .removePerson(member), let .approveRequest(member), let .rejectRequest(member):
            try fields.encode(member, forKey: .member)
        case let .setRole(member, role):
            try fields.encode(member, forKey: .member)
            try fields.encode(role, forKey: .role)
        default: break
        }
    }
}

/// An acknowledged edit can have per-person failures; an unconfirmed write is never retried implicitly.
public struct ConversationMutationResult: Codable, Hashable, Sendable {
    public var operationID: String
    public var details: ConversationDetails?
    public var failedMembers: [Member.ID]
    public var isConfirmed: Bool

    public init(
        operationID: String,
        details: ConversationDetails? = nil,
        failedMembers: [Member.ID] = [],
        isConfirmed: Bool = true
    ) {
        self.operationID = operationID
        self.details = details
        self.failedMembers = failedMembers
        self.isConfirmed = isConfirmed
    }
}
