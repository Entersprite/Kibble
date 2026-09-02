import ChatKit
import Foundation

/// A backend whose `loadMessages` blocks until the test releases it - the
/// shape of a hung `list_topics` call, which nothing at the `ChatSessionModel`
/// or `SyncEngine` layer can force to return early. `connect()` and
/// everything else succeed instantly, so a test using this is exercising
/// exactly one thing: a history fetch that outlives whoever asked for it.
actor HangingHistoryBackend: ChatBackend {
    nonisolated let capabilities = Capabilities()
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private var release: CheckedContinuation<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_: ChatCommand) async throws {}
    func loadConversations() async throws -> [Conversation] {
        []
    }

    func loadMessages(in conversation: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        await withCheckedContinuation { self.release = $0 }
        // Answers only once released, as though a slow server finally came
        // back - the message a caller that had already moved on must never
        // see land.
        return [Message(
            id: Message.ID("msg:late"),
            conversationID: conversation,
            threadID: MessageThread.ID("t-1"),
            sender: Member.ID("people/ghost"),
            text: "arrived after the session that asked for it had gone",
            createdAt: Date(timeIntervalSince1970: 1000)
        )]
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}

    /// Lets the blocked `loadMessages` call return. Safe to call at most
    /// once per fetch; a test drives this by hand rather than a clock.
    func releaseHungRequest() {
        release?.resume()
        release = nil
    }
}
