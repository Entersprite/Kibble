import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func sendOwnState(_ command: ChatCommand) async throws {
        if case let .setTyping(conversation, thread, typing) = command {
            try await setTyping(in: conversation, thread: thread, typing: typing)
        } else {
            try await setOwnStatus(command)
        }
    }

    func setTyping(in id: Conversation.ID, thread: MessageThread.ID?, typing: Bool) async throws {
        guard let client = apiClient, let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.unsupported(capability: "canSendTypingState")
        }
        let generation = directoryGeneration
        try Task.checkCancellation()
        do {
            _ = try await client.call(.setTypingState, TypingRequests.make(
                group: group, topic: thread?.rawValue, typing: typing
            ))
        } catch {
            if error is CancellationError {
                throw error
            }
            throw Self.chatError(fromAPI: error, call: "the typing state call")
        }
        guard generation == directoryGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }
}
