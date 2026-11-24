public extension Capabilities {
    func canSetConversationMute(in kind: Conversation.Kind) -> Bool {
        extendedFlags.contains("conversationMute")
            && [.space, .directMessage, .groupDirectMessage].contains(kind)
    }
}

public extension ChatBackend {
    func setConversationMute(_: Pause, in _: Conversation.ID) async throws {
        throw ChatError.unsupported(capability: "conversationMute")
    }
}
