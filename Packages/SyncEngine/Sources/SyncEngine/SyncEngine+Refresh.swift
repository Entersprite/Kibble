import ChatKit
import ChatPersistence
import Foundation

public extension SyncEngine {
    /// Reconciles server read state and the visible transcript after another
    /// client may have changed them while this app was in the background.
    /// The world load also updates the bridge's latest-head hint before the
    /// history request. The caller owns and cancels this task on sign-out.
    func refreshVisibleConversation(_ conversation: Conversation.ID?) async {
        do {
            let version = conversationMutationVersion
            let conversations = try await backend.loadConversations()
            try Task.checkCancellation()
            guard version == conversationMutationVersion else { return }
            try applyConversationSnapshot(conversations)
            worldLoaded()
            if let conversation, conversations.contains(where: { $0.id == conversation }) {
                try await loadMoreMessages(in: conversation)
            }
        } catch {
            guard !Task.isCancelled else { return }
            record(error)
        }
    }
}
