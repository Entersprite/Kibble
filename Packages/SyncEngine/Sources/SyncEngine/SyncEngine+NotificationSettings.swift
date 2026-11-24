import ChatKit

extension SyncEngine {
    func setSpaceNotificationLevel(_ level: NotificationLevel, in id: Conversation.ID) async throws {
        try Task.checkCancellation()
        try await backend.setNotificationSetting(level, for: id)
    }

    func setConversationMute(_ pause: Pause, in id: Conversation.ID) async throws {
        try Task.checkCancellation()
        try await backend.setConversationMute(pause, in: id)
    }
}
