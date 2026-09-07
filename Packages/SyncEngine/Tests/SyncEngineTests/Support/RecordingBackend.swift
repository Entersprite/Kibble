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
    private var failing = false
    private var holding = false
    /// A queue, not a single slot: a second `send(_:)` arriving while one is
    /// already held used to overwrite this without resuming it, orphaning the
    /// first caller permanently - a hang inside the suite's own time limit
    /// rather than a clear failure, which is the worst way for a harness bug
    /// to surface. A re-armed mark that itself needs to hold means two
    /// `send(_:)` calls can be in flight and held one after another in the
    /// same test, so this must be able to hold more than one at a time.
    private var heldSubmissions: [CheckedContinuation<Void, Never>] = []

    private(set) var loadMessagesCalls = 0

    init(world: FixtureWorld = .minimal, capabilities: Capabilities = .fixture) {
        inner = FakeBackend(world: world, capabilities: capabilities)
        self.capabilities = capabilities
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
        commands.append(command)
        if holding {
            await withCheckedContinuation { heldSubmissions.append($0) }
        }
        if failing {
            throw ChatError.notAuthenticated
        }
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
        return try await inner.loadMessages(in: conversation, before: before)
    }

    func setNotificationSetting(
        _ level: NotificationLevel,
        for conversation: Conversation.ID
    ) async throws {
        try await inner.setNotificationSetting(level, for: conversation)
    }
}
