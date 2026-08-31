import ChatKit
import Foundation

/// A backend that answers everything with a failure.
///
/// Exists to prove the sync loop survives one. It is also, incidentally, the
/// seam's third implementation - and it took thirty lines against `ChatKit`
/// alone, which is the claim `ChatBackend` is there to make.
actor FailingBackend: ChatBackend {
    nonisolated let capabilities = Capabilities()
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Pushes an event as if it had arrived from a server.
    func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_: ChatCommand) async throws {
        throw ChatError.notAuthenticated
    }

    func loadConversations() async throws -> [Conversation] {
        throw ChatError.server(status: 500, message: "nope")
    }

    func loadMessages(in _: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        throw ChatError.server(status: 500, message: "nope")
    }

    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {
        throw ChatError.notAuthenticated
    }
}
