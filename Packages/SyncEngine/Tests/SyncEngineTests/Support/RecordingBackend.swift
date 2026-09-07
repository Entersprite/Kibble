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
