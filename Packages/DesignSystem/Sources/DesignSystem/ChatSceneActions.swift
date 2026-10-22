import ChatKit
import Foundation

/// What the window can ask for. Closures rather than a protocol so the app can
/// wire them to anything, including nothing.
@MainActor
public struct ChatSceneActions {
    public var openMessageReference: ((MessageAddress) -> Void)?
    public var loadMessageReference: MessageReferenceLoader?
    public var forwardMessage: (@MainActor (Message.ID, Conversation.ID, String) async -> Bool)?
    public var invokeCardAction: AppCardActionHandler?
    public var openEmbeddedMedia: (@MainActor @Sendable (URL) -> Void)?
    public var checkMessageDelivery: ((Message.ID) -> Void)?
    public var preserveDraft: ((ComposerDraftAddress, ComposerDraft) -> Void)?
    public var showSidebarSettings: (() -> Void)?
    public var browser: ConversationBrowserActions?
    public var typingActivity: ((Conversation.ID, MessageThread.ID?, Bool) -> Void)?
    public var select: (Conversation.ID) -> Void
    public var selectMeetingSeries: ((MeetingSeries.ID) -> Void)?
    public var visibleMeetingMessages: ((Set<Message.ID>) -> Void)?
    public var send: (ComposedMessage) -> Void

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
    /// sign out of, so the sidebar footer, whose avatar menu offers this,
    /// draws nothing rather than a menu item with no effect.
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
    public var conversationActions: ConversationActions?

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

    /// A link preview's or app card's picture. **Optional, and `nil` draws
    /// cards without pictures** (`CLAUDE.md`: never draw a control the seam
    /// cannot honour).
    public var imageLoader: SceneImageLoader?
    public var loadRemoteImage: ((URL) async throws -> Data)?

    /// Download, cancel, open, reveal and Save As for a non-image file chip.
    /// **Optional, and `nil` is the point** - `CLAUDE.md`: never draw a
    /// control the seam cannot honour, so a backend that cannot download
    /// files draws a plain label instead of a click that goes nowhere.
    public var attachmentFiles: AttachmentFileActions?

    /// Toggle a reaction, from a capsule or the bubble's menu. **Optional,
    /// and `nil` is the point**: a backend that cannot react gets a read-only
    /// row and no menu.
    public var reactions: ReactionActions?

    /// Stage files to send: the composer's +, files dropped on the
    /// conversation, and removing one. **Optional, and `nil` is the point**:
    /// a backend that cannot upload gets neither the + nor a drop
    /// target.
    public var composerAttachments: ComposerAttachmentActions?

    /// The composer's active `@` query, for the directory section; `nil` when
    /// none (mention non-members spec §3.4). Optional: a host without it
    /// shows no directory section.
    public var directoryQuery: ((String?) -> Void)?
    /// A directory person was picked, so their membership is checked.
    public var memberPicked: ((Member.ID) -> Void)?
    /// Who in a message is not in the conversation, asked at Return.
    public var nonMembers: (@MainActor (ComposedMessage) async -> [Member.ID])?
    /// Sends into one conversation only while it is open; otherwise the
    /// message goes back to its draft.
    public var sendTo: ((ComposedMessage, Conversation.ID) -> Void)?
    /// Hands an unsent message back to its conversation's draft.
    public var keepDraft: ((ComposedMessage, Conversation.ID) -> Void)?
    /// Save an edit and delete a message, on the person's own messages.
    /// **Optional, and `nil` is the point** (edit spec §5).
    public var messages: MessageActions?
    /// Sets or clears your custom status. **Optional, and `nil` hides the
    /// status menu**, with `setAvailability`: a backend that cannot set status
    /// gets a plain name in the footer.
    public var setStatus: ((MemberStatus?) -> Void)?
    /// Sets your availability.
    public var setAvailability: ((Availability) -> Void)?
    /// Threads. **Optional, and `nil` is the point**: a backend without
    /// threads gets no mark, no panel and no Threads row.
    public var threads: ThreadActions?
    /// Search. **Optional, and `nil` is the point**: a backend that cannot
    /// search gets no overlay.
    public var search: SearchActions?
    /// Remembers that a sidebar section was collapsed or expanded, by
    /// `SidebarSection.id`; the host hands the set back in
    /// `ChatSceneState.collapsedSections`. **Optional**: a host that keeps none
    /// gets collapse the sidebar forgets at relaunch, as before.
    public var updateSidebar: ((SidebarPreferences) -> Void)?
    public var showDirectory: ((String) -> Void)?
    public var setSectionCollapsed: ((String, Bool) -> Void)?
    /// Opens the app's settings, from the sidebar footer's gear. **Optional,
    /// and `nil` draws no gear**: only the host knows whether it has settings
    /// and how to show them (on the Mac, SwiftUI's `openSettings`, which only a
    /// view can read).
    public var showSettings: (() -> Void)?
    /// Starts a DM audio call, or brings the existing call window forward.
    public var call: ((Conversation.ID) -> Void)?
    /// Starts a DM call with the camera on. **Optional**, beside `call`: only
    /// a host whose calls can carry video supplies it, and `nil` draws no
    /// Video Call button.
    public var videoCall: ((Conversation.ID) -> Void)?
    /// Page the selected transcript. Missing callbacks draw no paging controls.
    public var loadOlderMessages: (() -> Void)?
    public var loadNewerMessages: (() -> Void)?

    public init(
        typingActivity: ((Conversation.ID, MessageThread.ID?, Bool) -> Void)? = nil,
        select: @escaping (Conversation.ID) -> Void = { _ in },
        send: @escaping (ComposedMessage) -> Void = { _ in },
        signIn: (() -> Void)? = nil,
        signOut: (() -> Void)? = nil,
        reconnect: (() -> Void)? = nil,
        draftRestored: (() -> Void)? = nil,
        mute: ((Conversation.ID) -> Void)? = nil,
        unmute: ((Conversation.ID) -> Void)? = nil,
        markRead: ((Conversation.ID) -> Void)? = nil,
        conversationActions: ConversationActions? = nil,
        showNotificationSettings: ((Conversation.ID) -> Void)? = nil,
        showMentions: (() -> Void)? = nil,
        openMention: ((Conversation.ID, Message.ID) -> Void)? = nil,
        loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)? = nil,
        openAttachment: ((Attachment) async throws -> URL)? = nil,
        loadRemoteImage: ((URL) async throws -> Data)? = nil,
        attachmentFiles: AttachmentFileActions? = nil,
        reactions: ReactionActions? = nil,
        composerAttachments: ComposerAttachmentActions? = nil,
        directoryQuery: ((String?) -> Void)? = nil,
        memberPicked: ((Member.ID) -> Void)? = nil,
        nonMembers: (@MainActor (ComposedMessage) async -> [Member.ID])? = nil,
        sendTo: ((ComposedMessage, Conversation.ID) -> Void)? = nil,
        keepDraft: ((ComposedMessage, Conversation.ID) -> Void)? = nil,
        messages: MessageActions? = nil,
        setStatus: ((MemberStatus?) -> Void)? = nil,
        setAvailability: ((Availability) -> Void)? = nil,
        threads: ThreadActions? = nil,
        search: SearchActions? = nil,
        setSectionCollapsed: ((String, Bool) -> Void)? = nil,
        showSettings: (() -> Void)? = nil,
        call: ((Conversation.ID) -> Void)? = nil,
        loadOlderMessages: (() -> Void)? = nil,
        loadNewerMessages: (() -> Void)? = nil
    ) {
        self.typingActivity = typingActivity
        self.select = select
        self.send = send
        self.signIn = signIn
        self.signOut = signOut
        self.reconnect = reconnect
        self.draftRestored = draftRestored
        self.mute = mute
        self.unmute = unmute
        self.markRead = markRead
        self.conversationActions = conversationActions
        self.showNotificationSettings = showNotificationSettings
        self.showMentions = showMentions
        self.openMention = openMention
        self.loadAttachment = loadAttachment
        self.openAttachment = openAttachment
        self.loadRemoteImage = loadRemoteImage
        self.attachmentFiles = attachmentFiles
        self.reactions = reactions
        self.composerAttachments = composerAttachments
        self.directoryQuery = directoryQuery
        self.memberPicked = memberPicked
        self.nonMembers = nonMembers
        self.sendTo = sendTo
        self.keepDraft = keepDraft
        self.messages = messages
        self.setStatus = setStatus
        self.setAvailability = setAvailability
        self.threads = threads
        self.search = search
        self.setSectionCollapsed = setSectionCollapsed
        self.showSettings = showSettings
        self.call = call
        self.loadOlderMessages = loadOlderMessages
        self.loadNewerMessages = loadNewerMessages
    }
}
