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

    /// A confirmation that is not an error - `AppEnvironment`'s two
    /// diagnostic probes use this so a clean run does not draw under the
    /// same warning triangle a real failure does. Its own field rather than
    /// a second meaning for `lastError`, because that collapsing is exactly
    /// what put a triangle over a passing keychain check: `ChatError`'s
    /// `.unknown(String)` could not tell "the session broke" from "here is
    /// where the report went" apart once both had been rendered into plain
    /// text.
    public var notice: String?

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
        notice: String? = nil,
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
        self.notice = notice
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

    /// Take the person back to sign-in. **Optional, and its absence is the
    /// point**: `nil` means the host has no sign-in to offer here, so no
    /// affordance is drawn.
    ///
    /// A running session must leave this `nil`. Otherwise every transient
    /// banner - one rate limit, one hiccup on a reopen - would grow a button
    /// inviting a person to re-authenticate a session that is working, which
    /// is the more expensive wrong answer of the two.
    ///
    /// A host that has failed to launch supplies it. Before this existed the
    /// only escape from a failed launch was deleting a Keychain item by hand:
    /// a page-shape change (`findings.md` §18), a client rejected as an
    /// unsupported browser, or a `StoredSession` that no longer decodes all
    /// reproduce on every relaunch, and none of them is
    /// `ChatError.notAuthenticated`, which was the only input that reached
    /// sign-in.
    public var signIn: (() -> Void)?

    /// Stop looking at this account. **Optional, and `nil` for the same
    /// reason as `signIn`**: a host with no running session has nothing to
    /// sign out of, so the sidebar footer that offers this draws nothing
    /// rather than a button with no effect.
    ///
    /// Symmetric with `signIn` in shape, not in when each is offered:
    /// `signIn` is offered only from a *failed* launch, because a running
    /// session must never invite someone to re-authenticate over one
    /// transient banner. `signOut` is the opposite - it is exactly a
    /// *running* session that has an account to stop looking at - so a host
    /// supplies this while `.running`, not while `.failed`.
    ///
    /// The confirmation this leads to is not this closure's job: the host
    /// already owns one confirmation dialog for the existing Sign Out menu
    /// command, and this is the same action reached a second way, so it
    /// triggers that same dialog rather than a second one living here.
    public var signOut: (() -> Void)?

    public init(
        select: @escaping (Conversation.ID) -> Void = { _ in },
        send: @escaping (String) -> Void = { _ in },
        signIn: (() -> Void)? = nil,
        signOut: (() -> Void)? = nil
    ) {
        self.select = select
        self.send = send
        self.signIn = signIn
        self.signOut = signOut
    }
}
