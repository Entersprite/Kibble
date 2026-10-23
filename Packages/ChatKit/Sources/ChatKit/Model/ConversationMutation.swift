import Foundation

public enum ConversationMutation: Hashable, Sendable, Codable {
    case identity(name: String?, description: String?, access: ConversationAccess?)
    case details(ConversationDetailsPatch)
    case guidelines(String)
    case settings(ConversationSettingsPatch)
    /// An empty string restores the conversation's default avatar.
    case emoji(String)
    case saveWebhook(id: String?, name: String, avatarURL: String)
    case convertToSpace(name: String, emoji: String?, acknowledgingHistoryChange: Bool)
    case generateEmail, setEmailDelivery(Bool), deleteEmail
    case deleteWebhook(String)
    case addApp(Member.ID), removeApp(Member.ID)
    case addPeople([Member.ID])
    case removePerson(Member.ID)
    case setRole(Member.ID, ConversationRole)
    case setPersonBlocked(Member.ID, Bool)
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
        case .details: "details"
        case .guidelines: "guidelines"
        case .settings: "settings"
        case .emoji: "emoji"
        case let .saveWebhook(id, _, _): id == nil ? "createWebhook" : "editWebhook"
        case .addApp: "addApp"
        case .removeApp: "removeApp"
        case .convertToSpace: "convertToSpace"
        case .generateEmail: "generateEmail"
        case .setEmailDelivery: "setEmailDelivery"
        case .deleteEmail: "deleteEmail"
        case .deleteWebhook: "deleteWebhook"
        case .addPeople: "addPeople"
        case .removePerson: "removePerson"
        case let .setPersonBlocked(_, blocked): blocked ? "blockPerson" : "unblockPerson"
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
        case type, name, description, access, members, member, role, guidelines, settings, emoji, webhookID,
             avatarURL, enabled, acknowledgingHistoryChange, details
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let type = try fields.decode(String.self, forKey: .type)
        if let action = Self.simpleActions[type] {
            self = action; return
        }
        if let value = try Self.decodeSettings(type, fields: fields) {
            self = value; return
        }
        if let value = try Self.decodeIntegrations(type, fields: fields) {
            self = value; return
        }
        self = try Self.decodePeople(type, fields: fields) ?? .unknown(JSONValue(from: decoder))
    }

    private static func decodePeople(
        _ type: String, fields: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self? {
        switch type {
        case "identity": try .identity(
                name: fields.decodeIfPresent(String.self, forKey: .name),
                description: fields.decodeIfPresent(String.self, forKey: .description),
                access: fields.decodeIfPresent(ConversationAccess.self, forKey: .access)
            )
        case "addPeople": try .addPeople(fields.decode([Member.ID].self, forKey: .members))
        case "removePerson": try .removePerson(fields.decode(Member.ID.self, forKey: .member))
        case "blockPerson", "unblockPerson": try .setPersonBlocked(
                fields.decode(Member.ID.self, forKey: .member),
                type == "blockPerson"
            )
        case "setRole": try .setRole(
                fields.decode(Member.ID.self, forKey: .member), fields.decode(
                    ConversationRole.self,
                    forKey: .role
                )
            )
        case "approveRequest": try .approveRequest(fields.decode(Member.ID.self, forKey: .member))
        case "rejectRequest": try .rejectRequest(fields.decode(Member.ID.self, forKey: .member))
        default: nil
        }
    }

    private static func decodeSettings(
        _ type: String,
        fields: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self? {
        switch type {
        case "convertToSpace": try .convertToSpace(
                name: fields.decode(String.self, forKey: .name), emoji: fields.decodeIfPresent(
                    String.self,
                    forKey: .emoji
                ),
                acknowledgingHistoryChange: fields.decodeIfPresent(
                    Bool.self,
                    forKey: .acknowledgingHistoryChange
                ) ?? false
            )
        case "setEmailDelivery": try .setEmailDelivery(fields.decode(Bool.self, forKey: .enabled))
        case "settings": try .settings(fields.decode(
                ConversationSettingsPatch.self,
                forKey: .settings
            ))
        case "emoji": try .emoji(fields.decode(String.self, forKey: .emoji))
        case "details": try .details(fields.decode(ConversationDetailsPatch.self, forKey: .details))
        case "guidelines": try .guidelines(fields.decode(String.self, forKey: .guidelines))
        default: nil
        }
    }

    private static func decodeIntegrations(
        _ type: String,
        fields: KeyedDecodingContainer<CodingKeys>
    ) throws -> Self? {
        switch type {
        case "createWebhook", "editWebhook": try .saveWebhook(
                id: type == "editWebhook" ? fields.decode(String.self, forKey: .webhookID) : nil,
                name: fields.decode(String.self, forKey: .name),
                avatarURL: fields.decode(String.self, forKey: .avatarURL)
            )
        case "addApp": try .addApp(fields.decode(Member.ID.self, forKey: .member))
        case "removeApp": try .removeApp(fields.decode(Member.ID.self, forKey: .member))
        case "deleteWebhook": try .deleteWebhook(fields.decode(String.self, forKey: .webhookID))
        default: nil
        }
    }

    private static let simpleActions: [String: Self] = [
        "leave": .leave, "join": .join, "requestJoin": .requestJoin, "acceptInvitation": .acceptInvitation,
        "declineInvitation": .declineInvitation, "generateEmail": .generateEmail, "deleteEmail": .deleteEmail,
        "deleteSpace": .deleteSpace, "block": .block
    ]

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(payload) = self {
            try payload.encode(to: encoder); return
        }
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(action, forKey: .type)
        if try encodeSettings(to: &fields) {
            return
        }
        if try encodeIntegrations(to: &fields) {
            return
        }
        switch self {
        case let .identity(name, description, access):
            try fields.encodeIfPresent(name, forKey: .name)
            try fields.encodeIfPresent(description, forKey: .description)
            try fields.encodeIfPresent(access, forKey: .access)
        case let .addPeople(members): try fields.encode(members, forKey: .members)
        case let .removePerson(member), let .approveRequest(member), let .rejectRequest(member):
            try fields.encode(member, forKey: .member)
        case let .setPersonBlocked(member, _): try fields.encode(member, forKey: .member)
        case let .setRole(member, role):
            try fields.encode(member, forKey: .member)
            try fields.encode(role, forKey: .role)
        default: break
        }
    }

    private func encodeSettings(to fields: inout KeyedEncodingContainer<CodingKeys>) throws -> Bool {
        switch self {
        case let .convertToSpace(name, emoji, acknowledged):
            try fields.encode(name, forKey: .name)
            try fields.encodeIfPresent(emoji, forKey: .emoji)
            try fields.encode(acknowledged, forKey: .acknowledgingHistoryChange)
        case let .setEmailDelivery(value): try fields.encode(value, forKey: .enabled)
        case let .settings(value): try fields.encode(value, forKey: .settings)
        case let .emoji(value): try fields.encode(value, forKey: .emoji)
        case let .details(value): try fields.encode(value, forKey: .details)
        case let .guidelines(value): try fields.encode(value, forKey: .guidelines)
        default: return false
        }
        return true
    }

    private func encodeIntegrations(to fields: inout KeyedEncodingContainer<CodingKeys>) throws -> Bool {
        switch self {
        case let .saveWebhook(id, name, avatarURL):
            try fields.encodeIfPresent(id, forKey: .webhookID)
            try fields.encode(name, forKey: .name)
            try fields.encode(avatarURL, forKey: .avatarURL)
        case let .addApp(id), let .removeApp(id): try fields.encode(id, forKey: .member)
        case let .deleteWebhook(id): try fields.encode(id, forKey: .webhookID)
        default: return false
        }
        return true
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
