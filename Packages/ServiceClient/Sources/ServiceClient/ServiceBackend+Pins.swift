import ChatAPI
import ChatKit

public extension ServiceBackend {
    func pinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        do {
            let value = try await projected { try await queryMessagePins(in: conversation) }
            diagnostics.record(.pinReadFinished(count: value.messages.count))
            return value
        } catch {
            diagnostics.record(.pinReadFailed(stage: "read", failure: Self.pinFailureKind(error)))
            throw error
        }
    }

    func setMessagePinned(_ pinned: Bool, at address: MessageAddress) async throws -> PinnedMessages {
        try await call(SetMessagePinned(
            address: address, pinned: pinned,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}

extension ServiceBackend {
    private func queryMessagePins(in conversation: Conversation.ID) async throws -> PinnedMessages {
        do {
            return try await call(GetMessagePins(conversationID: conversation))
        } catch {
            diagnostics.record(.pinReadFailed(stage: "query", failure: Self.pinFailureKind(error)))
            throw error
        }
    }
}
