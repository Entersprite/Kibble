import ChatKit
import Foundation

public struct AccountSummary: Codable, Hashable, Sendable {
    public let id: ConnectedAccountID
    public let revision: ServiceAccountRevision?
    /// Changes whenever the provider runtime is replaced, including disable/re-enable.
    public let runtimeID: UUID?
    public let policyRevision: String?
    public let selfID: Member.ID
    public let label: String
    public let authenticationState: String?
    public let isRemoving: Bool
    public let isEnabled: Bool
    public let isReady: Bool
    public let capabilities: Capabilities
    public let connection: ConnectionState
    /// The account's last-known own identity; absent until the provider first
    /// identifies itself, and in summaries from older services.
    public let profile: AccountProfile?

    public init(
        id: ConnectedAccountID,
        selfID: Member.ID,
        label: String,
        connection: ConnectionState,
        isEnabled: Bool = true,
        isReady: Bool = false,
        isRemoving: Bool = false,
        capabilities: Capabilities = .init(),
        revision: ServiceAccountRevision? = nil,
        authenticationState: String? = nil, policyRevision: String? = nil, runtimeID: UUID? = nil,
        profile: AccountProfile? = nil
    ) {
        self.id = id
        self.revision = revision
        self.runtimeID = runtimeID
        self.selfID = selfID
        self.label = label
        self.connection = connection
        self.authenticationState = authenticationState
        self.policyRevision = policyRevision
        self.isRemoving = isRemoving
        self.isEnabled = isEnabled
        self.isReady = isReady
        self.capabilities = capabilities
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, selfID, label, connection, isReady, isEnabled, isRemoving, capabilities,
             authenticationState, policyRevision, runtimeID, profile
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(ConnectedAccountID.self, forKey: .id),
            selfID: values.decode(Member.ID.self, forKey: .selfID),
            label: values.decode(String.self, forKey: .label),
            connection: values.decode(ConnectionState.self, forKey: .connection),
            isEnabled: values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            isReady: values.decodeIfPresent(Bool.self, forKey: .isReady) ?? false,
            isRemoving: values.decodeIfPresent(Bool.self, forKey: .isRemoving) ?? false,
            capabilities: values.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? .init(),
            revision: values.decodeIfPresent(ServiceAccountRevision.self, forKey: .revision),
            authenticationState: values.decodeIfPresent(String.self, forKey: .authenticationState),
            policyRevision: values.decodeIfPresent(String.self, forKey: .policyRevision),
            runtimeID: values.decodeIfPresent(UUID.self, forKey: .runtimeID),
            profile: values.decodeIfPresent(AccountProfile.self, forKey: .profile)
        )
    }
}

public struct ListAccounts: ServiceRequestPayload {
    public typealias Response = [AccountSummary]
    public static let operation = "listAccounts"
    public static let requiresAccount = false

    public init() {}
}

public struct LoadConversations: ServiceRequestPayload {
    public typealias Response = [Conversation]
    public static let operation = "loadConversations"
    public static let requiresAccount = true

    public init() {}
}

/// Coverage is explicit: a partial page cannot establish absence or deletion.
public struct MessagePage: Codable, Hashable, Sendable {
    public let messages: [Message]
    public let nextCursor: String?
    public let isComplete: Bool
    public let checkpoint: ServiceCursor?

    public init(
        messages: [Message],
        nextCursor: String?,
        isComplete: Bool,
        checkpoint: ServiceCursor? = nil
    ) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.isComplete = isComplete
        self.checkpoint = checkpoint
    }
}

public struct LoadMessages: ServiceRequestPayload {
    public typealias Response = MessagePage
    public static let operation = "loadMessages"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let cursor: String?

    public init(conversationID: Conversation.ID, cursor: String? = nil) {
        self.conversationID = conversationID
        self.cursor = cursor
    }
}
