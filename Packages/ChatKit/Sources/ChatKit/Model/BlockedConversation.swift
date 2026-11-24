public struct BlockedConversation: Codable, Hashable, Identifiable, Sendable {
    public let id: Conversation.ID
    public let name: String

    public init(id: Conversation.ID, name: String) {
        self.id = id
        self.name = name
    }
}

public extension Capabilities {
    var canManageBlockedConversations: Bool {
        extendedFlags.contains("blockedConversations")
    }
}

public extension ChatBackend {
    func blockedConversations() async throws -> [BlockedConversation] {
        throw ChatError.unsupported(capability: "blockedConversations")
    }

    func unblockConversation(_: Conversation.ID) async throws -> [BlockedConversation] {
        throw ChatError.unsupported(capability: "blockedConversations")
    }
}
