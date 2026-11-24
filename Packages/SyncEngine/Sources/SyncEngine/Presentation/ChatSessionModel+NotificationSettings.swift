import ChatKit

public extension ChatSessionModel {
    func setSpaceNotificationLevel(_ level: NotificationLevel, in id: Conversation.ID) async throws {
        guard capabilities.canSetNotificationLevel, connectionState == .connected,
              conversations.contains(where: { $0.id == id && $0.kind == .space })
        else { throw ChatError.unsupported(capability: "canSetNotificationLevel") }
        try await engine.setSpaceNotificationLevel(level, in: id)
    }

    func setConversationMute(_ pause: Pause, in id: Conversation.ID) async throws {
        guard connectionState == .connected, let row = conversations.first(where: { $0.id == id }),
              capabilities.canSetConversationMute(in: row.kind)
        else { throw ChatError.unsupported(capability: "conversationMute") }
        try await engine.setConversationMute(pause, in: id)
    }
}
