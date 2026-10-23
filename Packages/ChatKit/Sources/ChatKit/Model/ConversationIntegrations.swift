import Foundation

public struct ConversationWebhook: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var allowedActions: Set<String>

    public init(id: String, name: String, avatarURL: URL? = nil, allowedActions: Set<String> = []) {
        self.id = id; self.name = name; self.avatarURL = avatarURL; self.allowedActions = allowedActions
    }

    private enum CodingKeys: String, CodingKey { case id, name, avatarURL, allowedActions }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        avatarURL = try fields.decodeIfPresent(URL.self, forKey: .avatarURL)
        allowedActions = try fields.decodeIfPresent(Set<String>.self, forKey: .allowedActions) ?? []
    }
}

public struct ConversationApp: Codable, Hashable, Sendable, Identifiable {
    public var member: Member
    public var description: String?
    public var allowedActions: Set<String>
    public var id: Member.ID {
        member.id
    }

    public init(member: Member, description: String? = nil, allowedActions: Set<String> = []) {
        self.member = member; self.description = description; self.allowedActions = allowedActions
    }

    private enum CodingKeys: String, CodingKey { case member, description, allowedActions }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        member = try fields.decode(Member.self, forKey: .member)
        description = try fields.decodeIfPresent(String.self, forKey: .description)
        allowedActions = try fields.decodeIfPresent(Set<String>.self, forKey: .allowedActions) ?? []
    }
}

/// Webhook delivery URLs are obtained separately and are never part of this listing.
public struct ConversationIntegrations: Codable, Hashable, Sendable {
    public var apps: [ConversationApp]
    public var canAddApps: Bool
    public var webhooks: [ConversationWebhook]
    public var canCreateWebhook: Bool

    public init(
        webhooks: [ConversationWebhook] = [],
        canCreateWebhook: Bool = false,
        apps: [ConversationApp] = [],
        canAddApps: Bool = false
    ) {
        self.apps = apps; self.canAddApps = canAddApps
        self.webhooks = webhooks; self.canCreateWebhook = canCreateWebhook
    }

    private enum CodingKeys: String, CodingKey { case webhooks, canCreateWebhook, apps, canAddApps }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        apps = try fields.decodeIfPresent([ConversationApp].self, forKey: .apps) ?? []
        canAddApps = try fields.decodeIfPresent(Bool.self, forKey: .canAddApps) ?? false
        webhooks = try fields.decodeIfPresent([ConversationWebhook].self, forKey: .webhooks) ?? []
        canCreateWebhook = try fields.decodeIfPresent(Bool.self, forKey: .canCreateWebhook) ?? false
    }
}
