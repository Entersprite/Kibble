import ChatKit
import ChatPersistence

public extension SyncEngine {
    func openDirectConversation(with member: Member.ID) async -> Conversation? {
        do {
            let version = conversationMutationVersion
            let conversation = try await backend.openDirectConversation(with: member)
            try Task.checkCancellation()
            guard version == conversationMutationVersion else { return nil }
            invalidateConversationSnapshot(conversation.id)
            try store.apply([.restoreConversation(conversation)])
            return conversation
        } catch {
            if !Task.isCancelled {
                record(error)
            }
            return nil
        }
    }
}
