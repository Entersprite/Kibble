import ChatKit

public extension SyncEngine {
    func submitConversationAction(_ action: ConversationAction, in id: Conversation.ID) async -> ChatError? {
        invalidateConversationSnapshot(id)
        defer { invalidateConversationSnapshot(id) }
        do {
            try await backend.send(.conversationAction(conversationID: id, action: action))
            try Task.checkCancellation()
            return nil
        } catch {
            let failure = error as? ChatError ?? .unknown(String(describing: error))
            if !Task.isCancelled {
                record(failure)
            }
            return failure
        }
    }
}

extension SyncEngine {
    /// A read started before a mutation cannot restore the earlier snapshot.
    func invalidateConversationSnapshot(_ id: Conversation.ID) {
        conversationMutationVersion += 1
        conversationVersions[id, default: 0] += 1
    }
}
