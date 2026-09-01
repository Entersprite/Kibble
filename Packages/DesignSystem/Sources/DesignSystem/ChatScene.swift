import ChatKit
import Foundation

/// Everything the chat window draws, as one value.
///
/// A struct of plain data rather than a reference to a store: a view built this
/// way renders from a literal in a preview or a test, and cannot accidentally
/// reach past the seam for something it was not given.
public struct ChatSceneState: Sendable, Equatable {
    public var conversations: [Conversation]
    public var directory: [Member.ID: Member]
    public var me: Member.ID?
    public var selected: Conversation.ID?
    public var messages: [Message]
    public var typing: [Member.ID]
    public var connection: ConnectionState
    public var lastError: ChatError?

    /// What the backend behind all this can actually do. The window reads it
    /// rather than assuming, which is the entire reason `Capabilities` exists:
    /// offering an action a backend cannot perform is worse than not offering
    /// it.
    public var capabilities: Capabilities

    public init(
        conversations: [Conversation] = [],
        directory: [Member.ID: Member] = [:],
        me: Member.ID? = nil,
        selected: Conversation.ID? = nil,
        messages: [Message] = [],
        typing: [Member.ID] = [],
        connection: ConnectionState = .idle,
        lastError: ChatError? = nil,
        capabilities: Capabilities = Capabilities()
    ) {
        self.conversations = conversations
        self.directory = directory
        self.me = me
        self.selected = selected
        self.messages = messages
        self.typing = typing
        self.connection = connection
        self.lastError = lastError
        self.capabilities = capabilities
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selected }
    }
}

/// What the window can ask for. Closures rather than a protocol so the app can
/// wire them to anything, including nothing.
@MainActor
public struct ChatSceneActions {
    public var select: (Conversation.ID) -> Void
    public var send: (String) -> Void

    public init(
        select: @escaping (Conversation.ID) -> Void = { _ in },
        send: @escaping (String) -> Void = { _ in }
    ) {
        self.select = select
        self.send = send
    }
}
