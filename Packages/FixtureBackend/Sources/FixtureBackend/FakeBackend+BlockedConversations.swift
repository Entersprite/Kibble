import ChatKit

public extension FakeBackend {
    func blockedConversations() throws -> [BlockedConversation] {
        try requireConnected()
        try require(capabilities.canManageBlockedConversations, "blockedConversations")
        return blockedRooms.values.map { item in
            BlockedConversation(id: item.conversation.id, name: item.conversation.title ?? "")
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func unblockConversation(_ id: Conversation.ID) throws -> [BlockedConversation] {
        try requireConnected()
        try require(capabilities.canManageBlockedConversations, "blockedConversations")
        if let item = blockedRooms.removeValue(forKey: id), item.wasJoined, world.conversation(id) == nil {
            world.conversations.append(item.conversation)
            emit(.conversationUpdated(item.conversation))
        }
        return try blockedConversations()
    }
}
