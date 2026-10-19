import ChatKit

/// Presentation-only draft scope within one account. IDs remain opaque.
public struct ComposerDraftAddress: Hashable, Sendable {
    public let conversation: Conversation.ID
    public let thread: MessageThread.ID?

    public init(conversation: Conversation.ID, thread: MessageThread.ID? = nil) {
        self.conversation = conversation
        self.thread = thread
    }
}
