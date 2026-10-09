import ChatKit
import FixtureBackend
import Foundation

/// A backend that forwards to `FakeBackend` and remembers what it was handed.
///
/// The seam's fourth implementation, and a decorator rather than a fresh fake:
/// `FakeBackend.markRead(_:upTo:)` already does the right thing (clears
/// `unreadCount`, emits `.readStateChanged`), and a second fake would have had
/// to reimplement that to get a call count. `FailingBackend` next door is the
/// other shape - a fake that answers everything with a failure - and this one
/// can do that too, on demand, because the auto-mark watermark rule depends on
/// telling a failed submission from a suppressed one.
actor RecordingBackend: ChatBackend {
    nonisolated let capabilities: Capabilities
    nonisolated var events: AsyncStream<ChatEvent> {
        inner.events
    }

    private nonisolated let inner: FakeBackend
    private(set) var commands: [ChatCommand] = []
    /// Every `.watchPresence`, kept out of `commands`: it is sent on every
    /// selection, and would otherwise race a mark for `commands.last` in
    /// tests that are about marks.
    private(set) var watches: [[Member.ID]] = []
    private var failing = false
    private var holding = false
    private var accepting = false
    private var failingHistory = false
    /// A queue, not a single slot: a second `send(_:)` arriving while one is
    /// already held used to overwrite this without resuming it, orphaning the
    /// first caller permanently - a hang inside the suite's own time limit
    /// rather than a clear failure, which is the worst way for a harness bug
    /// to surface. A re-armed mark that itself needs to hold means two
    /// `send(_:)` calls can be in flight and held one after another in the
    /// same test, so this must be able to hold more than one at a time.
    private var heldSubmissions: [CheckedContinuation<Void, Never>] = []
    /// `holdSubmissions`, but torn down by the caller's cancellation, as a
    /// request on the wire is (`AbortableHold`).
    nonisolated let abortableSubmissions = AbortableHold()
    private var holdingAbortably = false

    private(set) var loadMessagesCalls = 0
    /// Every `uploadAttachment` call, in order, failed ones included.
    private(set) var uploads: [OutgoingAttachment] = []
    private var failingUploads = false
    private var holdingUploads = false
    private var heldUploads: [CheckedContinuation<Void, Never>] = []

    init(world: FixtureWorld = .minimal, capabilities: Capabilities = .fixture, directory: [Member] = []) {
        inner = FakeBackend(world: world, capabilities: capabilities, directory: directory)
        self.capabilities = capabilities
    }

    // MARK: - People (mention non-members spec §3.4)

    private(set) var searches: [String] = []
    private var holdingSearches = false
    private var heldSearches: [CheckedContinuation<Void, Never>] = []
    private var failingSearches = false
    private var echoingQueries = false
    private(set) var membershipChecks: [Member.ID] = []
    private var holdingMemberships = false
    private var heldMemberships: [CheckedContinuation<Void, Never>] = []

    func holdSearches(_ hold: Bool) {
        holdingSearches = hold
    }

    func failSearches(_ fail: Bool) {
        failingSearches = fail
    }

    /// Answers each search with one person whose id is the query, so a test
    /// can tell which query's answer was published.
    func echoQueries(_ echo: Bool) {
        echoingQueries = echo
    }

    func holdMemberships(_ hold: Bool) {
        holdingMemberships = hold
    }

    var heldSearchCount: Int {
        heldSearches.count
    }

    var heldMembershipCount: Int {
        heldMemberships.count
    }

    /// Releases the held search at `index` (0 is the oldest).
    func releaseHeldSearch(at index: Int = 0) {
        guard heldSearches.indices.contains(index) else { return }
        heldSearches.remove(at: index).resume()
    }

    func releaseHeldMembership() {
        guard !heldMemberships.isEmpty else { return }
        heldMemberships.removeFirst().resume()
    }

    func searchPeople(_ query: String) async throws -> [Member] {
        searches.append(query)
        if holdingSearches {
            await withCheckedContinuation { heldSearches.append($0) }
        }
        if failingSearches {
            throw ChatError.server(status: 500, message: "the search failed")
        }
        if echoingQueries {
            return [Member(id: Member.ID(query), kind: .human, displayName: query)]
        }
        return try await inner.searchPeople(query)
    }

    func membership(
        of member: Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        membershipChecks.append(member)
        if holdingMemberships {
            await withCheckedContinuation { heldMemberships.append($0) }
        }
        return try await inner.membership(of: member, in: conversation)
    }

    /// Makes every later `send(_:)` record the command and then throw, without
    /// forwarding it.
    func failSubmissions(_ shouldFail: Bool) {
        failing = shouldFail
    }

    /// Makes every later `send(_:)` record the command, then block until
    /// `releaseHeldSubmission()` is called - the shape of a mark-read (or any
    /// other command) that has been issued but has not yet come back, which
    /// is exactly the window `AutoMarkReadTests`' in-flight-suppression test
    /// needs to hold open. Same idiom as `HangingHistoryBackend`, but as a
    /// gate on this backend's `send(_:)` rather than a separate backend, so
    /// the test can still read `commands`/`markReadCount` while it is held.
    func holdSubmissions(_ shouldHold: Bool) {
        holding = shouldHold
    }

    /// Holds every later `send(_:)` in `abortableSubmissions`.
    func holdSubmissionsAbortably(_ shouldHold: Bool) {
        holdingAbortably = shouldHold
    }

    /// Makes every later `send(_:)` record the command and succeed **without**
    /// forwarding it to the fixture backend.
    ///
    /// Written for one sequence that cannot otherwise exist:
    /// `FakeBackend.send(_:)` throws once disconnected, and
    /// `ChatSessionModel.stop()` disconnects. So a mark held open across
    /// `stop()` and then released always fails for *that* reason, and
    /// `publishReadPosition`'s own `Task.isCancelled` guard is never the
    /// thing that declines - deleting that guard leaves such a test green,
    /// which is the definition of no coverage.
    ///
    /// What it models is real, and is what the guard exists for:
    /// `stop()`'s doc comment says cancelling a task does not oblige the
    /// request underneath it to abort, so a `mark_group_readstate` already in
    /// flight can be *accepted* by the server after sign-out. This is that
    /// case, and the watermark must still not advance.
    func acceptWithoutForwarding(_ shouldAccept: Bool) {
        accepting = shouldAccept
    }

    /// Makes every later `loadMessages` count the call and then throw, the
    /// shape of a newest-page fetch that fails while the channel still takes
    /// commands - so an explicit mark's fallback to the stored newest message
    /// can be told from a mark that never fetched.
    func failHistory(_ shouldFail: Bool) {
        failingHistory = shouldFail
    }

    /// Makes every later `uploadAttachment` record the file and then throw,
    /// without forwarding it.
    func failUploads(_ shouldFail: Bool) {
        failingUploads = shouldFail
    }

    /// Makes every later `uploadAttachment` record the file, then block until
    /// `releaseHeldUpload()`: an upload that has started and not answered.
    func holdUploads(_ shouldHold: Bool) {
        holdingUploads = shouldHold
    }

    func releaseHeldUpload() {
        guard !heldUploads.isEmpty else { return }
        heldUploads.removeFirst().resume()
    }

    var heldUploadCount: Int {
        heldUploads.count
    }

    /// Releases the oldest `send(_:)` call currently blocked by
    /// `holdSubmissions(true)`, if any - first held, first released. Safe to
    /// call when nothing is held.
    func releaseHeldSubmission() {
        guard !heldSubmissions.isEmpty else { return }
        heldSubmissions.removeFirst().resume()
    }

    /// How many `send(_:)` calls are blocked right now. A test asserts on
    /// this directly to prove "no third concurrent call started", rather
    /// than inferring it from `markReadCount` alone - a third call would
    /// still increment this even if it happened to race the fixture's clock
    /// in a way that left `markReadCount` ambiguous.
    var heldSubmissionCount: Int {
        heldSubmissions.count
    }

    var markReadCount: Int {
        commands.count {
            if case .markRead = $0 {
                true
            } else {
                false
            }
        }
    }

    /// Lets a test prove a repeated `.connected` observation does not refetch
    /// history twice - no assertion other than a query count can express that.
    var loadMessagesCount: Int {
        loadMessagesCalls
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        if case let .watchPresence(members) = command {
            watches.append(members)
            try await inner.send(command)
            return
        }
        commands.append(command)
        // A member load is recorded and can be failed, but never held: the
        // holds sequence marks and sends, and selecting a space now also
        // submits `.loadMembers`, which would take a held slot a test counts.
        let holdable = if case .loadMembers = command {
            false
        } else {
            true
        }
        if holding, holdable {
            await withCheckedContinuation { heldSubmissions.append($0) }
        }
        if holdingAbortably, holdable {
            try await abortableSubmissions.wait()
        }
        if failing {
            throw ChatError.notAuthenticated
        }
        guard !accepting else { return }
        try await inner.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(
        in conversation: Conversation.ID,
        before: Message.ID?
    ) async throws -> [Message] {
        loadMessagesCalls += 1
        if failingHistory {
            throw ChatError.notAuthenticated
        }
        return try await inner.loadMessages(in: conversation, before: before)
    }

    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        uploads.append(attachment)
        if holdingUploads {
            await withCheckedContinuation { heldUploads.append($0) }
        }
        if failingUploads {
            throw ChatError.server(status: 400, message: "the upload's bytes were refused")
        }
        // `acceptWithoutForwarding` covers uploads too: an upload that
        // answers after `stop()` has disconnected the fixture.
        if accepting {
            return Attachment(
                id: "accepted-\(attachment.id)",
                name: attachment.name,
                contentType: attachment.contentType
            )
        }
        return try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }

    func setNotificationSetting(
        _ level: NotificationLevel,
        for conversation: Conversation.ID
    ) async throws {
        try await inner.setNotificationSetting(level, for: conversation)
    }

    // MARK: - Threads (threads spec §4.3)

    /// Every `loadThread` call's thread, in order.
    private(set) var threadLoads: [MessageThread.ID] = []
    /// Every `setThreadFollowed` call's value, in order.
    private(set) var followRequests: [Bool] = []
    private(set) var followedThreadLoads = 0
    /// Scripted per test and never forwarded: the fixture's own threads are
    /// FixtureBackend's subject, and these suites must say exactly what a
    /// page holds.
    private var threadPages: [MessageThread.ID: [Message]] = [:]
    private var followedAnswer: [Message] = []
    private var failingThreadCalls = false
    private var holdingThreadCalls = false
    private var heldThreadCalls: [CheckedContinuation<Void, Never>] = []

    func answerThread(_ thread: MessageThread.ID, with page: [Message]) {
        threadPages[thread] = page
    }

    func answerFollowedThreads(with messages: [Message]) {
        followedAnswer = messages
    }

    /// Makes every later thread request record itself and then throw.
    func failThreadCalls(_ fail: Bool) {
        failingThreadCalls = fail
    }

    /// Makes every later thread request record itself, then wait for
    /// `releaseHeldThreadCall()`: a request asked and not yet answered.
    func holdThreadCalls(_ hold: Bool) {
        holdingThreadCalls = hold
    }

    var heldThreadCallCount: Int {
        heldThreadCalls.count
    }

    /// Releases the oldest held thread request, if any.
    func releaseHeldThreadCall() {
        guard !heldThreadCalls.isEmpty else { return }
        heldThreadCalls.removeFirst().resume()
    }

    func loadThread(_ thread: MessageThread.ID, in _: Conversation.ID) async throws -> [Message] {
        threadLoads.append(thread)
        try await threadCallGate()
        return threadPages[thread] ?? []
    }

    func setThreadFollowed(_ followed: Bool, thread _: MessageThread.ID, in _: Conversation.ID) async throws {
        followRequests.append(followed)
        try await threadCallGate()
    }

    func loadFollowedThreads() async throws -> [Message] {
        followedThreadLoads += 1
        try await threadCallGate()
        return followedAnswer
    }

    /// Recording happens before this, in the same actor turn, so a test that
    /// saw the call recorded knows it has already passed the hold check.
    private func threadCallGate() async throws {
        if holdingThreadCalls {
            await withCheckedContinuation { heldThreadCalls.append($0) }
        }
        if failingThreadCalls {
            throw ChatError.server(status: 500, message: "the thread call failed")
        }
    }
}
