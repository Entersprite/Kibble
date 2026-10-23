import ChatKit

public extension SyncEngine {
    /// Whether a call is going on in a conversation, as the backend observes it
    /// now. Nil when the backend does not advertise discovery: the client then
    /// knows nothing, which is never the same as no call. Nothing is stored;
    /// transcript call entries remain history.
    func callAvailability(in id: Conversation.ID) async throws -> ConversationCallAvailability? {
        guard capabilities.canDiscoverCalls, let discovery = backend as? any CallDiscoveryBackend else {
            return nil
        }
        return try await discovery.callAvailability(in: id)
    }
}

public extension ChatSessionModel {
    /// The engine's answer, for the conversation the caller watches.
    func callAvailability(in id: Conversation.ID) async throws -> ConversationCallAvailability? {
        try await engine.callAvailability(in: id)
    }
}
