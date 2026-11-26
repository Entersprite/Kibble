import ChatKit
import Foundation

public extension SyncEngine {
    func pinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        let generation = managementGeneration
        try Task.checkCancellation()
        let value = try await backend.pinnedMessages(in: conversation)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        if !(backend is any ProjectedChatBackend) {
            try store.apply([.replaceMessagePins(conversation: conversation, pins: value)])
        }
        return value
    }

    func setMessagePinned(_ pinned: Bool, message: Message) async throws -> PinnedMessages {
        let generation = managementGeneration
        let value = try await backend.setMessagePinned(pinned, at: MessageAddress(
            conversation: message.conversationID, thread: message.threadID, message: message.id
        ))
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return value
    }
}
