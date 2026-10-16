import ChatKit
import Foundation

/// What the sidebar has chosen: a conversation, the Mentions row (the
/// mentions-list spec §4), or the Threads row. A view type, so it lives here
/// (ruling 1). The session model says `showingMentions`, `threads.showingList`
/// and `selected`, and `ChatSceneState.sidebarSelection` is the one place they
/// become this.
public enum SidebarSelection: Hashable, Sendable {
    case conversation(Conversation.ID)
    case mentions
    case threads
}

/// Everything the chat window draws, as one value.
///
/// A struct of plain data rather than a reference to a store: a view built this
/// way renders from a literal in a preview or a test, and cannot accidentally
/// reach past the seam for something it was not given.
public struct ChatSceneState: Sendable, Equatable {
    public var browser: ConversationBrowserScene = .init()
    public var conversations: [Conversation]
    public var directory: [Member.ID: Member]
    public var me: Member.ID?
    /// Your own availability, for the status menu's checkmark.
    public var availability: Availability?
    public var selected: Conversation.ID?
    public var messages: [Message]
    public var hasOlderMessages: Bool
    public var isLoadingOlderMessages: Bool
    public var newerMessagesAreLatestJump: Bool
    public var hasNewerMessages: Bool
    public var isLoadingNewerMessages: Bool
    public var activity: ConversationActivity
    public var pendingMessages: Set<Message.ID>
    public var typing: [Member.ID]
    public var connection: ConnectionState
    /// Supplied by the host for connection diagnostics; `nil` uses neutral wording.
    public var connectionService: ConnectionService?
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
    /// Conversations the current call service can call. An empty set hides Call.
    public var callableConversations: Set<Conversation.ID>

    /// A send that was not accepted, mentions and all, for the composer to
    /// adopt. `nil` in every ordinary frame.
    public var failedDraft: ComposedMessage?

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
    /// The selected conversation's `@` list, ranked
    /// (`ChatSessionModel.mentionCandidates`).
    public var mentionCandidates: [Member]
    /// The `@` list's directory section for the active query
    /// (`ChatSessionModel.directoryResults`).
    public var directoryResults: [Member]
    /// Threads: the marks' summaries, the panel, the list (threads spec §5).
    public var threads: ThreadSceneState
    /// Search: the overlay and the results bar (search spec §1).
    public var search: SearchSceneState
    /// The message the transcript marks once, after a search opened it.
    public var highlightedMessage: Message.ID?
    /// One more on every hit a search opens, so the same hit opened again
    /// scrolls and marks again (`TranscriptScroll.Request`).
    public var searchOpenGeneration: Int
    /// The sidebar sections a person has collapsed, by `SidebarSection.id`.
    /// The host keeps them across launches (`ChatSceneActions.setSectionCollapsed`).
    public var sidebarPreferences: SidebarPreferences = .init()
    public var collapsedSections: Set<String>

    public init(
        conversations: [Conversation] = [],
        directory: [Member.ID: Member] = [:],
        me: Member.ID? = nil,
        availability: Availability? = nil,
        selected: Conversation.ID? = nil,
        messages: [Message] = [],
        hasOlderMessages: Bool = false,
        isLoadingOlderMessages: Bool = false,
        hasNewerMessages: Bool = false,
        newerMessagesAreLatestJump: Bool = false,
        isLoadingNewerMessages: Bool = false,
        typing: [Member.ID] = [],
        activity: ConversationActivity = ConversationActivity(), pendingMessages: Set<Message.ID> = [],
        connection: ConnectionState = .idle,
        connectionService: ConnectionService? = nil,
        lastError: ChatError? = nil,
        notice: String? = nil,
        capabilities: Capabilities = Capabilities(),
        failedDraft: ComposedMessage? = nil,
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
        stagedAttachments: [ComposerAttachment] = [],
        mentionCandidates: [Member] = [],
        directoryResults: [Member] = [],
        threads: ThreadSceneState = ThreadSceneState(),
        search: SearchSceneState = SearchSceneState(),
        highlightedMessage: Message.ID? = nil,
        searchOpenGeneration: Int = 0,
        collapsedSections: Set<String> = [],
        sidebarPreferences: SidebarPreferences = .init(),
        callableConversations: Set<Conversation.ID> = []
    ) {
        self.conversations = conversations
        self.directory = directory
        self.me = me
        self.availability = availability
        self.selected = selected
        self.messages = messages
        self.hasOlderMessages = hasOlderMessages
        self.isLoadingOlderMessages = isLoadingOlderMessages
        self.hasNewerMessages = hasNewerMessages
        self.newerMessagesAreLatestJump = newerMessagesAreLatestJump
        self.isLoadingNewerMessages = isLoadingNewerMessages
        self.typing = typing
        self.activity = activity
        self.pendingMessages = pendingMessages
        self.connection = connection
        self.connectionService = connectionService
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
        self.mentionCandidates = mentionCandidates
        self.directoryResults = directoryResults
        self.threads = threads
        self.search = search
        self.highlightedMessage = highlightedMessage
        self.searchOpenGeneration = searchOpenGeneration
        self.collapsedSections = collapsedSections
        self.sidebarPreferences = sidebarPreferences
        self.callableConversations = callableConversations
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selected }
    }

    public var sidebarSelection: SidebarSelection? {
        if showingMentions {
            return .mentions
        }
        if threads.showingList {
            return .threads
        }
        return selected.map(SidebarSelection.conversation)
    }
}
