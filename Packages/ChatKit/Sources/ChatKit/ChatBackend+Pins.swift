import Foundation

public extension ChatBackend {
    func pinnedMessages(in _: Conversation.ID) async throws -> PinnedMessages {
        throw ChatError.unsupported(capability: "messagePins")
    }

    func setMessagePinned(_: Bool, at _: MessageAddress) async throws -> PinnedMessages {
        throw ChatError.unsupported(capability: "messagePins")
    }
}
