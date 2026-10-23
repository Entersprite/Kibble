import ChatKit

public extension FakeBackend {
    func pinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        try requireConnected()
        try require(capabilities.canReadMessagePins, "messagePins")
        guard world.conversation(conversation) != nil else {
            throw ChatError.decoding("This conversation is unavailable.")
        }
        return PinnedMessages(
            messages: world.pinnedMessageIDs.compactMap { world.message($0) }
                .filter { $0.conversationID == conversation && !$0.isDeleted },
            members: world.members, canModify: true
        )
    }

    func setMessagePinned(_ pinned: Bool, at address: MessageAddress) async throws -> PinnedMessages {
        _ = try await pinnedMessages(in: address.conversation)
        guard let id = address.message, let message = world.message(id),
              message.conversationID == address.conversation, message.threadID == address.thread,
              !message.isDeleted, message.callStatus == nil, message.activity == nil else {
            throw ChatError.decoding("This message cannot be pinned.")
        }
        world.pinnedMessageIDs.removeAll { $0 == id }
        if pinned {
            world.pinnedMessageIDs.insert(id, at: 0)
        }
        emit(.messagePinsChanged(address.conversation))
        return try await pinnedMessages(in: address.conversation)
    }
}
