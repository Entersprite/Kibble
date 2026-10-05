import ChatKit
import Foundation

/// What the sidebar has chosen: a conversation, or the Mentions row (the
/// mentions-list spec §4). A view type, so it lives here (ruling 1). The
/// session model says `showingMentions` and `selected`, and
/// `ChatSceneState.sidebarSelection` is the one place the two become this.
public enum SidebarSelection: Hashable, Sendable {
    case conversation(Conversation.ID)
    case mentions
}

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

    /// Text from a send that was not accepted, for the composer to adopt.
    /// `nil` in every ordinary frame.
    public var failedDraft: String?

    /// Conversations whose rule hides the unread indicator - drawn read in the
    /// sidebar whatever `hasUnread` says (spec §3). The flag itself is untouched:
    /// the badge and the rules still read it.
    public var unreadHidden: Set<Conversation.ID>

    /// Conversations whose resolved delivery is Off - drawn dimmed, so a
    /// silent section or the Meet preset dims too (spec §2.5).
    public var dimmed: Set<Conversation.ID>

    /// Conversations whose **own** record says Off - the ones the context
    /// menu offers to Unmute, and that show the bell.
    public var muted: Set<Conversation.ID>

    /// Conversations whose rule withholds read receipts - where Mark as Read
    /// would be refused at `SyncEngine.submit`, so the menu does not offer it.
    public var receiptsWithheld: Set<Conversation.ID>

    /// Whether the Mentions row is chosen. `selected` is then `nil`, and it
    /// keeps meaning "the selected conversation, if any" for every reader.
    public var showingMentions: Bool

    /// The Mentions list, newest first (the mentions-list spec §4).
    public var mentions: [MentionItem]
    public var mentionsStatus: MentionsStatus

    /// The Mentions row's badge: every unread mention, not only those listed.
    public var unreadMentionCount: Int

    /// The message the transcript scrolls to once, after a mention is opened.
    public var scrollTarget: Message.ID?

    /// Each file attachment's download, keyed by `Attachment.id`. An absent
    /// key is `.idle` - see `AttachmentDownloadState`.
    public var downloads: [String: AttachmentDownloadState]

    /// The selected conversation's staged files, for the composer.
    public var stagedAttachments: [ComposerAttachment]

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
        capabilities: Capabilities = Capabilities(),
        failedDraft: String? = nil,
        unreadHidden: Set<Conversation.ID> = [],
        dimmed: Set<Conversation.ID> = [],
        muted: Set<Conversation.ID> = [],
        receiptsWithheld: Set<Conversation.ID> = [],
        showingMentions: Bool = false,
        mentions: [MentionItem] = [],
        mentionsStatus: MentionsStatus = MentionsStatus(),
        unreadMentionCount: Int = 0,
        scrollTarget: Message.ID? = nil,
        downloads: [String: AttachmentDownloadState] = [:],
        stagedAttachments: [ComposerAttachment] = []
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
        self.failedDraft = failedDraft
        self.unreadHidden = unreadHidden
        self.dimmed = dimmed
        self.muted = muted
        self.receiptsWithheld = receiptsWithheld
        self.showingMentions = showingMentions
        self.mentions = mentions
        self.mentionsStatus = mentionsStatus
        self.unreadMentionCount = unreadMentionCount
        self.scrollTarget = scrollTarget
        self.downloads = downloads
        self.stagedAttachments = stagedAttachments
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selected }
    }

    public var sidebarSelection: SidebarSelection? {
        showingMentions ? .mentions : selected.map(SidebarSelection.conversation)
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

    /// Hurry a reconnect along. **Optional, and `nil` for the same reason as
    /// `signIn` and `signOut`**: most of the time nothing is broken, and
    /// `StatusStrip` draws the button only where `ConnectionBanner
    /// .offersReconnect` says the wait has earned one *and* the host actually
    /// supplied this - a window with no route out here is not a fallback
    /// worth building, because the reducer keeps retrying either way.
    public var reconnect: (() -> Void)?

    /// Told by the composer that it has adopted `state.failedDraft`, so the
    /// host can stop offering it. **Optional, and its absence is the point** -
    /// a host that offers no restore hook simply gets the old behaviour, the
    /// same pattern `signIn`, `signOut` and `reconnect` already use.
    public var draftRestored: (() -> Void)?

    /// Mute and Unmute a conversation (spec §2.5). **Optional, and `nil`
    /// hides the menu items**: rules belong to an account, so a host with no
    /// identified account offers neither - the `StatusStrip` pattern.
    public var mute: ((Conversation.ID) -> Void)?
    public var unmute: ((Conversation.ID) -> Void)?

    /// Publishes the conversation's read position - the sidebar's Mark as
    /// Read. `nil` hides it: no identified account, or a backend that cannot
    /// mark read.
    public var markRead: ((Conversation.ID) -> Void)?

    /// Opens "Notifications for <name>". The host presents it; `nil` hides
    /// the menu item.
    public var showNotificationSettings: ((Conversation.ID) -> Void)?

    /// Shows the Mentions list. `nil` hides the row: a host with no running
    /// session has no mentions to show (the `StatusStrip` pattern).
    public var showMentions: (() -> Void)?

    /// Opens a mention: its conversation, scrolled to its message.
    public var openMention: ((Conversation.ID, Message.ID) -> Void)?

    /// An attachment's bytes, at a size. **Optional, and `nil` draws no
    /// image**: a backend that cannot fetch gets the file's name instead of a
    /// placeholder that never fills (`CLAUDE.md`: never draw a control the
    /// seam cannot honour). Async, because the bytes are a round trip away.
    public var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?

    /// The full-size image as a file, for Quick Look. `nil` makes an image
    /// not clickable.
    public var openAttachment: ((Attachment) async throws -> URL)?

    /// Download, cancel, open, reveal and Save As for a non-image file chip.
    /// **Optional, and `nil` is the point** - `CLAUDE.md`: never draw a
    /// control the seam cannot honour, so a backend that cannot download
    /// files draws a plain label instead of a click that goes nowhere.
    public var attachmentFiles: AttachmentFileActions?

    /// Toggle a reaction, from a capsule or the bubble's menu. **Optional,
    /// and `nil` is the point**: a backend that cannot react gets a read-only
    /// row and no menu.
    public var reactions: ReactionActions?

    /// Stage files to send: the composer's paperclip, files dropped on the
    /// conversation, and removing one. **Optional, and `nil` is the point**:
    /// a backend that cannot upload gets neither the paperclip nor a drop
    /// target.
    public var composerAttachments: ComposerAttachmentActions?

    public init(
        select: @escaping (Conversation.ID) -> Void = { _ in },
        send: @escaping (String) -> Void = { _ in },
        signIn: (() -> Void)? = nil,
        signOut: (() -> Void)? = nil,
        reconnect: (() -> Void)? = nil,
        draftRestored: (() -> Void)? = nil,
        mute: ((Conversation.ID) -> Void)? = nil,
        unmute: ((Conversation.ID) -> Void)? = nil,
        markRead: ((Conversation.ID) -> Void)? = nil,
        showNotificationSettings: ((Conversation.ID) -> Void)? = nil,
        showMentions: (() -> Void)? = nil,
        openMention: ((Conversation.ID, Message.ID) -> Void)? = nil,
        loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)? = nil,
        openAttachment: ((Attachment) async throws -> URL)? = nil,
        attachmentFiles: AttachmentFileActions? = nil,
        reactions: ReactionActions? = nil,
        composerAttachments: ComposerAttachmentActions? = nil
    ) {
        self.select = select
        self.send = send
        self.signIn = signIn
        self.signOut = signOut
        self.reconnect = reconnect
        self.draftRestored = draftRestored
        self.mute = mute
        self.unmute = unmute
        self.markRead = markRead
        self.showNotificationSettings = showNotificationSettings
        self.showMentions = showMentions
        self.openMention = openMention
        self.loadAttachment = loadAttachment
        self.openAttachment = openAttachment
        self.attachmentFiles = attachmentFiles
        self.reactions = reactions
        self.composerAttachments = composerAttachments
    }
}
