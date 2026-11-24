import ChatAPI
import ChatKit

public extension ServiceBackend {
    func blockedConversations() async throws -> [BlockedConversation] {
        try await call(GetBlockedConversations())
    }

    func unblockConversation(_ id: Conversation.ID) async throws -> [BlockedConversation] {
        try await call(UnblockConversation(
            conversation: id, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
