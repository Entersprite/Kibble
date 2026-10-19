import ChatKit
import Foundation

/// Drives one backend into one store.
///
/// The **single consumer** of `backend.events`. `AsyncStream` distributes
/// elements unpredictably across concurrent
/// iterations, so exactly one place in a client may iterate it - and this is
/// that place. Anything else that wants events reads the store.
///
/// The loop is deliberately unkillable by ordinary failure. A store write that
/// throws, or a backend that cannot answer a re-fetch, is recorded as the last
/// error and the loop carries on: a client that stopped syncing because one old
/// message was missing would be worse than one showing a stale banner.
public actor SyncEngine {
    /// Not `private`: `SyncEngine+Presence.swift` sends through it too.
    let backend: any ChatBackend
    /// Not `private`: `SyncEngine+MentionBackfill.swift` reads and writes it.
    let store: ChatStore
    var starting = false
    var deliveryReconciliation: Task<Void, Never>?
    var consumer: Task<Void, Never>?
    let typingTiming: TypingTiming
    var typingLeases: [TypingKey: TypingLease] = [:]
    var typingExpiry: Task<Void, Never>?
    var activityRunning = false
    public nonisolated let typingPrivacy = TypingPrivacyGate()
    var typingPublisher: Task<Void, Never>?
    var typingPublisherGeneration = 0
    var desiredTyping: TypingUpdate?
    var typingLastSent: ContinuousClock.Instant?
    var sentTyping: TypingUpdate?
    var clientTransportAvailable = true
    var clientTransportObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    var typingIdle: Task<Void, Never>?

    /// Whether this client is refusing to publish anything about itself.
    ///
    /// **No longer how read receipts are decided, and no host sets it.**
    /// Receipts are decided per conversation by the resolved rule's
    /// `readReceipts` field, read at submit time through the gate below
    /// (`ReadReceiptGate`); the old hidden `ghostMode` preference migrates
    /// into the first real account's global rule (`NotificationSettingsModel`,
    /// in `AppCore`). The switch remains for legacy callers: it still suppresses `.setTyping`; the current
    /// account rule and submission-time typing gate govern ordinary composition.
    /// See `GhostModeTests` for what it does and does not cover - in particular the `PingEvent` fields it
    /// cannot reach.
    var ghostMode = false
    var conversationMutationVersion = 0
    var managementGeneration = 0
    var conversationVersions: [Conversation.ID: Int] = [:]

    public var isGhosting: Bool {
        ghostMode
    }

    public func setGhostMode(_ enabled: Bool) {
        ghostMode = enabled
    }

    /// What the backend behind this engine can do. Forwarded rather than
    /// copied, so it cannot drift from the thing that enforces it.
    public nonisolated var capabilities: Capabilities {
        backend.capabilities
    }

    public nonisolated var tracksMessageDelivery: Bool {
        backend is any MessageDeliveryTrackingBackend
    }

    /// Arrivals and read-position changes, for whatever turns them into
    /// notifications.
    ///
    /// **One stream, one consumer, for the life of this engine** - a session's
    /// `NotificationCoordinator` attachment. Cancelling a task suspended in its
    /// `next()` finishes it for good (`findings.md` §25.10), which is correct
    /// here only because an engine is built per session and the consumer is
    /// detached exactly when the session ends. `.bufferingNewest` so an engine
    /// nobody listens to - every test, a probe - cannot grow without bound, and
    /// so a consumer attached a moment late still hears what it missed.
    public nonisolated let announcements: AsyncStream<SyncAnnouncement>
    nonisolated let announcer: AsyncStream<SyncAnnouncement>.Continuation

    /// Read receipts per conversation. See `ReadReceiptGate`.
    public nonisolated let readReceipts = ReadReceiptGate()

    /// The "now" for the Mentions backfill's 30-day window
    /// (`SyncEngine+MentionBackfill.swift`). Backfill runs only when the
    /// backend advertises `needsMentionBackfill` and a clock is supplied.
    /// `nil`, the default, still disables it for callers without a clock.
    /// Not `private`, for that file.
    let mentionClock: (@Sendable () -> Date)?

    /// The backfill run in flight, if any. Changed worlds, real gaps and
    /// `stop()` can cancel it; unchanged foreground worlds retain it.
    var mentionBackfillTask: Task<Void, Never>?
    var mentionBackfillGeneration = 0
    var mentionBackfillHeads: [Conversation.ID: MentionBackfillHead] = [:]
    var mentionBackfillCandidates: [Conversation.ID: MentionBackfillHead] = [:]

    /// Conversations whose members this session has asked for
    /// (`SyncEngine+Members.swift`). Forgotten on failure and on `stop()`.
    var membersLoaded: Set<Conversation.ID> = []

    /// Roots already checked against their own server topic this session.
    /// History pages are windows, so absence from a page alone proves nothing.
    var checkedMissingRoots: Set<Message.ID> = []
    var meetingMetadataUpdates: [Conversation.ID: MeetingMetadataUpdate] = [:]
    var meetingMetadataSequence = 0

    /// The Threads list fetch a world load started (`SyncEngine+Threads.swift`),
    /// canceled by the next world load and by `stop()`.
    var followedThreadsTask: Task<Void, Never>?

    public init(
        backend: any ChatBackend, store: ChatStore, mentionClock: (@Sendable () -> Date)? = nil,
        typingTiming: TypingTiming = TypingTiming()
    ) {
        self.typingTiming = typingTiming
        self.backend = backend
        self.store = store
        self.mentionClock = mentionClock
        (announcements, announcer) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Stops consuming and disconnects.
    ///
    /// Awaits the consumer so no further event can reach the store after this returns.
    public func stop() async {
        managementGeneration += 1
        activityRunning = false
        let reconciliation = deliveryReconciliation
        deliveryReconciliation = nil
        reconciliation?.cancel()
        await reconciliation?.value
        typingIdle?.cancel()
        desiredTyping = nil
        typingPublisher?.cancel()
        typingPublisherGeneration += 1
        typingPublisher = nil
        sentTyping = nil
        typingExpiry?.cancel()
        typingLeases = [:]
        try? store.apply([.clearActivityTyping])
        consumer?.cancel()
        await consumer?.value
        consumer = nil
        meetingMetadataUpdates = [:]
        // After the drain, so a run started by the consumer's last event is
        // cancelled too. Not awaited, for `ChatSessionModel.historyTask`'s
        // reason: a fetch that ignores cancellation would hang sign-out with
        // it. `loadMoreMessages`' own check is what keeps a late page out.
        mentionBackfillTask?.cancel()
        mentionBackfillGeneration += 1
        mentionBackfillHeads = [:]
        mentionBackfillCandidates = [:]
        membersLoaded = []
        checkedMissingRoots = []
        mentionBackfillTask = nil
        followedThreadsTask?.cancel()
        followedThreadsTask = nil
        await backend.disconnect()
    }

    /// Fetches a page of history for a conversation and files it.
    ///
    /// On demand, because connecting does not fetch history: doing so would
    /// mean an unbounded read on every launch for a workspace with hundreds of
    /// conversations. A view calls this when the user opens a conversation, and
    /// again with the oldest message it holds when they scroll up.
    @discardableResult
    public func loadMoreMessages(
        in conversation: Conversation.ID, before: Message.ID? = nil,
        verifyCachedRoots: Bool = false
    ) async throws -> [Message] {
        let version = conversationVersions[conversation, default: 0]
        let page = try await backend.loadMessages(in: conversation, before: before)
        // The caller may have stopped caring while `backend.loadMessages`
        // was in flight - `ChatSessionModel.stop()` cancels the `Task` this
        // runs under whenever a conversation's history fetch outlives the
        // session that asked for it. Cancelling that `Task` does not promise
        // the network call above was itself aborted, so this check is what
        // actually stops the write from landing once it does return: without
        // it, a hung `list_topics` answering after a sign-out has already
        // erased the store would repopulate it with the account that just
        // left.
        try Task.checkCancellation()
        if backend is any ProjectedChatBackend {
            return page
        }
        guard version == conversationVersions[conversation, default: 0] else { return [] }
        try store.apply(page.map { .upsertMessage($0) })
        if verifyCachedRoots, before == nil {
            await verifyMissingRoots(in: conversation, against: page)
        }
        return page
    }
}
