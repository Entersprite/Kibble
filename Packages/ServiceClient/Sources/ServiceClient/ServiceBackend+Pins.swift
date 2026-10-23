import ChatAPI
import ChatKit

public extension ServiceBackend {
    func pinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        try await call(GetMessagePins(conversationID: conversation))
    }

    func setMessagePinned(_ pinned: Bool, at address: MessageAddress) async throws -> PinnedMessages {
        try await call(SetMessagePinned(
            address: address, pinned: pinned,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
