import ChatAPI
import ChatKit

extension ServiceBackend: CallDiscoveryBackend {
    public func callAvailability(
        in conversationID: Conversation.ID
    ) async throws -> ConversationCallAvailability {
        try await call(GetCallAvailability(conversationID: conversationID))
    }
}
