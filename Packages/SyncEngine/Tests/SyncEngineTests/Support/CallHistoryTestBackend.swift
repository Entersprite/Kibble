import ChatKit
import FixtureBackend
import Foundation

/// A backend whose call history answers a scripted page per cursor, records
/// every query exactly as it arrived, and can hold an answer until released.
/// Everything else is `RecordingBackend`'s.
actor CallHistoryTestBackend: ChatBackend, CallHistoryBackend {
    nonisolated let inner: RecordingBackend
    nonisolated var capabilities: Capabilities {
        inner.capabilities
    }

    nonisolated var events: AsyncStream<ChatEvent> {
        inner.events
    }

    init(capabilities: Capabilities = .fixture) {
        inner = RecordingBackend(capabilities: capabilities)
    }

    private(set) var queries: [CallHistoryQuery] = []
    /// What each cursor answers; `nil` is the first page. A missing cursor fails.
    private var pages: [String?: CallHistoryPage] = [:]
    private var failing: Set<String?> = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int {
        held.count
    }

    func answer(_ page: CallHistoryPage, after cursor: String?) {
        pages[cursor] = page
        failing.remove(cursor)
    }

    func fail(after cursor: String?) {
        failing.insert(cursor)
    }

    func hold() {
        holding = true
    }

    func release() {
        holding = false
        let waiting = held; held = []
        waiting.forEach { $0.resume() }
    }

    func callHistory(_ query: CallHistoryQuery) async throws -> CallHistoryPage {
        queries.append(query)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        guard !failing.contains(query.cursor), let page = pages[query.cursor] else {
            throw ChatError.unknown("history unavailable")
        }
        return page
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        try await inner.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await inner.loadMessages(in: conversation, before: before)
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) async throws {
        try await inner.setNotificationSetting(level, for: conversation)
    }

    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws
        -> Attachment {
        try await inner.uploadAttachment(attachment, to: conversation, progress: progress)
    }
}
