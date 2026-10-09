import Foundation

/// The seam.
///
/// Everything above this protocol is a chat client; everything below it is one
/// way of talking to Google. A fake backend, an in-process backend driving the
/// real internal protocol, and a client of a remote bridge server all conform
/// to it, and the app cannot tell which it has — which is the property the
/// whole package exists to buy.
///
/// `Sendable` and `async` throughout because a backend is a long-lived thing
/// with a network connection, and the client that drives it is a UI.
public protocol ChatBackend: Sendable {
    /// What this backend can do. Read it before offering the user an action:
    /// every flag defaults to `false`, so a backend that has not thought about
    /// a capability is treated as not having it.
    ///
    /// Static for the lifetime of the backend. A capability that can change
    /// while connected would need an event, and nothing needs that yet.
    var capabilities: Capabilities { get }

    /// Starts connecting. Returns once the attempt has been *started or has
    /// failed outright*; progress is reported through `events` as
    /// `connectionStateChanged`, because reconnection is a lifetime concern and
    /// not a property of one call.
    func connect() async throws

    /// Stops. Deliberately non-throwing: there is nothing a caller could do
    /// about a failure to disconnect, and shutdown paths that can throw get
    /// written wrong.
    func disconnect() async

    /// The event stream.
    ///
    /// Two requirements on an implementation, both load-bearing:
    ///
    /// 1. **One stream for the backend's lifetime.** This property must hand
    ///    back the same stream every time, and that stream must **not finish on
    ///    `disconnect()`** — disconnection is an event
    ///    (`connectionStateChanged(.disconnected)`), not the end of the
    ///    conversation. A client that iterates this once, at launch, must be
    ///    able to keep iterating it across every disconnect and reconnect for
    ///    as long as the process lives. Finishing the stream on disconnect
    ///    breaks that loop permanently, and the bug looks like "the app stops
    ///    updating after the network blips".
    ///
    /// 2. **Single consumer.** `AsyncStream` distributes elements across
    ///    concurrent iterations arbitrarily — two `for await` loops over one
    ///    stream do not each see every element, they split them
    ///    unpredictably. So exactly one place in the client may iterate this,
    ///    and anything else that needs events gets them from that place. If
    ///    genuine multicasting is needed later, it belongs in a client-side
    ///    broadcaster, not in every backend.
    var events: AsyncStream<ChatEvent> { get }

    /// Submits a command. Throws only if the command could not be submitted —
    /// not connected, or `capabilities` says no. The *outcome* arrives as an
    /// event.
    func send(_ command: ChatCommand) async throws

    /// The conversation list, fully replacing whatever the client had.
    func loadConversations() async throws -> [Conversation]

    // [Verify] `before:` as a message-id cursor is an OPEN QUESTION, recorded
    // here rather than designed away. The wire protocol has no message-id
    // cursor: its model is two-level - topics containing messages - and it
    // pages by revision anchors and per-topic page sizes. `ListTopicsRequest`
    // takes `page_size_for_topics`, `page_size_for_replies` and
    // `user_not_older_than` / `group_not_older_than` reference revisions;
    // `CatchUpGroupRequest` takes a `CatchUpRange` of revision timestamps.
    // Read from the vendored `googlechat.proto` in this repo, not from
    // documentation, and not yet exercised against a live account.
    //
    // So a backend implementing this has to translate an opaque `Message.ID`
    // into whatever anchor it actually pages by, and it is entirely possible
    // that this parameter becomes an opaque `HistoryCursor` once we have seen
    // one page work. The signature is deliberately left exactly as it stands:
    // guessing at a cursor type before seeing a real page would be a worse
    // mistake than changing this signature later.
    /// A page of history, oldest-to-newest, ending just before `before`.
    ///
    /// `before: nil` means "the most recent page". See the `[Verify]` note
    /// immediately above this declaration: the cursor type is provisional.
    func loadMessages(
        in conversation: Conversation.ID,
        before: Message.ID?
    ) async throws -> [Message]

    /// Changes a conversation's notification level.
    ///
    /// Separate from `send(_:)` even though `ChatCommand` has a
    /// `setNotificationLevel` case, because this one has a completion a caller
    /// genuinely needs to await: a settings toggle must not spring back while a
    /// round trip is in flight. The command case exists for a bridge server
    /// forwarding it on.
    func setNotificationSetting(
        _ level: NotificationLevel,
        for conversation: Conversation.ID
    ) async throws

    /// An attachment's bytes, at `size`. See the default below for why this
    /// is a request rather than a command, and what a backend that has not
    /// implemented it does.
    ///
    /// **A requirement, not only an extension method, on purpose.** A method
    /// declared only in an extension is dispatched statically, so through
    /// `any ChatBackend` the refusing default would run even on a backend that
    /// implements it (`AttachmentDataTests`).
    func attachmentData(_ attachment: Attachment, size: AttachmentSize) async throws -> Data

    /// Downloads a file attachment into `destination`, reporting progress as
    /// the bytes arrive. The backend writes `destination` and, on any failure
    /// or cancellation, removes whatever it wrote there, so a caller never
    /// finds a partial file. `destination` must not exist. Cancellation is the
    /// calling task's.
    ///
    /// **A requirement, not only an extension method**, for the reason
    /// `attachmentData(_:size:)` gives.
    func downloadAttachment(
        _ attachment: Attachment,
        to destination: URL,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws

    /// A custom emoji's image. **A requirement, not only an extension
    /// method**, for the reason `attachmentData(_:size:)` gives.
    func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data

    /// A picture a message points at - a link preview's or an app card's
    /// (links spec §3.3) - from a URL Google gave. **A requirement, not only
    /// an extension method**, for the reason `attachmentData(_:size:)` gives.
    func remoteImage(_ url: URL) async throws -> Data

    /// People in the directory matching `query`, for the `@` list (mention
    /// non-members spec §3.1). **A requirement, not only an extension
    /// method**, for the reason `attachmentData(_:size:)` gives.
    func searchPeople(_ query: String) async throws -> [Member]

    /// Whether `member` is in `conversation` now. A requirement for the same
    /// reason.
    func membership(of member: Member.ID, in conversation: Conversation.ID) async throws
        -> ConversationMembership

    /// Uploads a staged file into `conversation` and returns the attachment a
    /// `ChatCommand.sendMessage` then carries. Nothing is posted: an upload
    /// that is never sent is believed to be invisible to everyone `[Verify]`. Progress counts bytes
    /// sent, in `AttachmentProgress.bytesReceived`'s place. Cancellation is
    /// the calling task's.
    ///
    /// A request rather than a command for the reason `attachmentData` is
    /// one: the bytes are megabytes, and a command frame should carry a
    /// reference, never the file.
    ///
    /// **A requirement, not only an extension method**, for the reason
    /// `attachmentData(_:size:)` gives.
    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment

    /// One thread's messages, oldest first, its first message included, each
    /// with `Message.isReply` set (threads spec §1). A request because the
    /// panel waits for it. **A requirement, not only an extension method**,
    /// for the reason `attachmentData(_:size:)` gives.
    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async throws -> [Message]

    /// Follows or unfollows a thread, and throws when that is refused. A
    /// request because a toggle must not spring back while the round trip is
    /// in flight, as with `setNotificationSetting`; the new state also
    /// arrives as `.threadChanged` with `.followed`. A requirement for the
    /// same reason.
    func setThreadFollowed(
        _ followed: Bool,
        thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) async throws

    /// The Threads list: each followed thread's first message and the reply
    /// the answer carries. **In no promised order:** the client stores them
    /// and orders the list itself, from its own read. Each thread's state also
    /// arrives as `.threadChanged`. A request because the client awaits it
    /// when the Threads pane opens, as the panel awaits `loadThread`. A
    /// requirement, for `attachmentData(_:size:)`'s reason.
    func loadFollowedThreads() async throws -> [Message]
}

/// Separate from the protocol body only so the default can sit beside it.
public extension ChatBackend {
    /// The default `attachmentData(_:size:)`.
    ///
    /// A request and its answer rather than a command and an event, because
    /// the bytes are megabytes and the event stream has one consumer: an image
    /// pushed through it would go through the reducer to reach a view.
    /// `attachment.id` is the backend's own opaque handle, handed back.
    ///
    /// The default refuses, so a backend that has not thought about
    /// attachments is one that cannot fetch them, the direction
    /// `Capabilities` defaults in. A backend that can overrides this and sets
    /// `canFetchAttachments`.
    func attachmentData(_: Attachment, size _: AttachmentSize) async throws -> Data {
        throw ChatError.unsupported(capability: "canFetchAttachments")
    }

    /// The default refuses, so a backend that has not thought about downloads
    /// is one that cannot do them, the direction `Capabilities` defaults in.
    func downloadAttachment(
        _: Attachment, to _: URL, progress _: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        throw ChatError.unsupported(capability: "canDownloadFiles")
    }

    /// Refuses, so a backend that has not thought about custom emoji draws
    /// their shortcodes, the direction `Capabilities` defaults in.
    func customEmojiImage(_: CustomEmojiRef) async throws -> Data {
        throw ChatError.unsupported(capability: "canFetchCustomEmoji")
    }

    /// Refuses, so a backend that has not thought about remote images draws
    /// cards without pictures, the direction `Capabilities` defaults in.
    func remoteImage(_: URL) async throws -> Data {
        throw ChatError.unsupported(capability: "canFetchRemoteImages")
    }

    /// Refuses, so a backend that has not thought about the directory offers
    /// no outside people, the direction `Capabilities` defaults in.
    func searchPeople(_: String) async throws -> [Member] {
        throw ChatError.unsupported(capability: "canMentionNonMembers")
    }

    /// Refuses, for the same reason.
    func membership(of _: Member.ID, in _: Conversation.ID) async throws -> ConversationMembership {
        throw ChatError.unsupported(capability: "canMentionNonMembers")
    }

    /// Refuses, so a backend that has not thought about uploads offers no way
    /// to attach a file, the direction `Capabilities` defaults in.
    func uploadAttachment(
        _: OutgoingAttachment,
        to _: Conversation.ID,
        progress _: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        throw ChatError.unsupported(capability: "canSendAttachments")
    }

    /// Refuses, so a backend that has not thought about threads offers no
    /// panel, the direction `Capabilities` defaults in.
    func loadThread(_: MessageThread.ID, in _: Conversation.ID) async throws -> [Message] {
        throw ChatError.unsupported(capability: "supportsThreads")
    }

    /// Refuses, for the same reason.
    func setThreadFollowed(_: Bool, thread _: MessageThread.ID, in _: Conversation.ID) async throws {
        throw ChatError.unsupported(capability: "supportsThreads")
    }

    /// Refuses, for the same reason.
    func loadFollowedThreads() async throws -> [Message] {
        throw ChatError.unsupported(capability: "supportsThreads")
    }
}
