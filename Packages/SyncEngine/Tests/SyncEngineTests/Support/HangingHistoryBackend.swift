import ChatKit
import Foundation

/// A backend whose `loadMessages` blocks until the test releases it - the
/// shape of a hung `list_topics` call, which nothing at the `ChatSessionModel`
/// or `SyncEngine` layer can force to return early. `connect()` and
/// everything else succeed instantly, so a test using this is exercising
/// exactly one thing: a history fetch that outlives whoever asked for it.
actor HangingHistoryBackend: ChatBackend {
    /// No capabilities by default, as before. `canMarkRead: true` is for a
    /// test that drives `ChatSessionModel.markRead(_:)`, whose first guard is
    /// the capability - without it the explicit mark returns before it ever
    /// reaches the fetch this backend hangs.
    nonisolated let capabilities: Capabilities
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private var release: CheckedContinuation<Void, Never>?

    /// Every command `send(_:)` was handed, in order. Actor-isolated, so a
    /// test reads it with `await` from any isolation.
    private(set) var commands: [ChatCommand] = []

    /// Set by `releaseHungRequest(throwing:)`, consumed the next time
    /// `loadMessages` wakes up. Modelling a *failure* the hung call answers
    /// with, rather than only ever a message - see that method's doc comment.
    private var pendingFailure: (any Error)?

    init(canMarkRead: Bool = false) {
        capabilities = Capabilities(canMarkRead: canMarkRead)
        (events, continuation) = AsyncStream.makeStream(
            of: ChatEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ command: ChatCommand) async throws {
        commands.append(command)
    }

    func loadConversations() async throws -> [Conversation] {
        []
    }

    func loadMessages(in conversation: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        await withCheckedContinuation { self.release = $0 }
        // A pending failure wins over the ordinary answer below - see
        // `releaseHungRequest(throwing:)`.
        if let pendingFailure {
            self.pendingFailure = nil
            throw pendingFailure
        }
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

    /// Whether a `loadMessages` call is blocked right now - what a test waits
    /// for before acting, so it acts on a fetch that is genuinely in flight
    /// and a later release cannot miss it.
    var isHoldingARequest: Bool {
        release != nil
    }

    /// Lets the blocked `loadMessages` call return with a message. Safe to
    /// call at most once per fetch; a test drives this by hand rather than a
    /// clock.
    func releaseHungRequest() {
        release?.resume()
        release = nil
    }

    /// Lets the blocked `loadMessages` call return by *throwing* `error`
    /// instead of answering with a message.
    ///
    /// Models the real shape a cancelled `/api/` call takes: cancelling the
    /// `Task` awaiting `URLSessionTransport` does not abort `loadMessages`
    /// here any more than it does in production - nothing at this layer can
    /// force a hung call to return early - but once whatever finally wakes it
    /// answers, it should be able to answer with a *transport-shaped* failure
    /// such as `ChatError.transport("... transport error (NSURLErrorDomain
    /// -999)")`, never `CancellationError` itself. A test uses this to prove
    /// `SyncEngine.requestMoreMessages` tells "our own task was cancelled"
    /// from "the error merely looks like one" by asking `Task.isCancelled`,
    /// not by matching the error's type - the same error can be handed to a
    /// task that was cancelled and to one that was not, and only the first
    /// should stay unrecorded.
    func releaseHungRequest(throwing error: any Error) {
        pendingFailure = error
        release?.resume()
        release = nil
    }
}
