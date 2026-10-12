import ChatKit

@MainActor
public struct ConversationActions {
    public var capabilities: Capabilities
    public var perform: (ConversationAction, Conversation.ID) -> Void

    public init(
        capabilities: Capabilities,
        perform: @escaping (ConversationAction, Conversation.ID) -> Void
    ) {
        self.capabilities = capabilities
        self.perform = perform
    }
}
