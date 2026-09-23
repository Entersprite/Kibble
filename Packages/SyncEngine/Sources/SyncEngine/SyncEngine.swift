import ChatKit
import Foundation

/// Drives one backend into one store.
///
/// The **single consumer** of `backend.events`. `ChatBackend` documents that an
/// `AsyncStream` distributes elements unpredictably across concurrent
/// iterations, so exactly one place in a client may iterate it - and this is
/// that place. Anything else that wants events reads the store.
///
/// The loop is deliberately unkillable by ordinary failure. A store write that
/// throws, or a backend that cannot answer a re-fetch, is recorded as the last
/// error and the loop carries on: a client that stopped syncing because one old
/// message was missing would be worse than one showing a stale banner.
public actor SyncEngine {
    private let backend: any ChatBackend
    private let store: ChatStore
    private var consumer: Task<Void, Never>?

    /// Whether this client is refusing to publish anything about itself.
    ///
    /// See `GhostModeTests`' own doc comment for what this does and does not
    /// cover - in particular the `PingEvent` fields it cannot reach. Defaults
    /// to `false`, which means read receipts are published: the owner's
    /// explicit call, so that the first live run exercises
    /// `mark_group_readstate` rather than a suppressed code path.
    private var ghostMode = false

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
    private nonisolated let announcer: AsyncStream<SyncAnnouncement>.Continuation

    public init(backend: any ChatBackend, store: ChatStore) {
        self.backend = backend
        self.store = store
        (announcements, announcer) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    /// Clears what was only true last time, starts consuming, then connects.
    ///
    /// Consuming starts *before* connecting so that nothing emitted during
    /// connection can be missed. Calling this twice does nothing the second
    /// time.
    public func start() async throws {
        guard consumer == nil else { return }
        try store.apply([.clearEphemeralState])
        let stream = backend.events
        consumer = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled {
                    return
                }
                await self?.handle(event)
            }
        }
        try await backend.connect()
    }

    /// Stops consuming and disconnects.
    ///
    /// Awaits the consuming task rather than only cancelling it, so that after
    /// this returns no further event can reach the store. A test - or a window
    /// closing - can then rely on the store standing still.
    public func stop() async {
        consumer?.cancel()
        await consumer?.value
        consumer = nil
        await backend.disconnect()
    }

    /// Fetches a page of history for a conversation and files it.
    ///
    /// On demand, because connecting does not fetch history: doing so would
    /// mean an unbounded read on every launch for a workspace with hundreds of
    /// conversations. A view calls this when the user opens a conversation, and
    /// again with the oldest message it holds when they scroll up.
    public func loadMoreMessages(in conversation: Conversation.ID, before: Message.ID? = nil) async throws {
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
        try store.apply(page.map { .upsertMessage($0) })
    }
}

// MARK: - Sending

public extension SyncEngine {
    /// Submits a command, recording a refusal where the UI can see it.
    ///
    /// `ChatBackend.send(_:)` throws only when a command could not be
    /// submitted - not connected, or a capability the backend does not have -
    /// and both are things a person should be told about rather than a silent
    /// no-op. The command's *outcome* arrives as an event, like everything
    /// else.
    ///
    /// **A throw also undoes what the caller optimistically claimed**, and
    /// `undoing` is how the caller says what that was. The optimistic row
    /// written by `ChatSessionModel.send` renders identically to a delivered
    /// message and survives relaunch, so leaving it behind tells the user
    /// their message was sent when it was not - and invites a re-send that, on
    /// a lost response to a POST that did land, posts the message twice for
    /// real. The retraction and the error go in one transaction, so a window
    /// can never draw one without the other.
    ///
    /// **The writes come from the caller rather than being inferred here, and
    /// that is a correctness requirement rather than a style choice.** This
    /// actor sees a `ChatCommand`, which carries a `localID` and no row
    /// identity. Retracting on that `localID` would delete the *delivered*
    /// message whenever the echo arrived before the failure did, because the
    /// server echoes the client's `localID` back onto the real message. Only
    /// the caller that wrote the optimistic row knows the id it invented, so
    /// only the caller can name the row that is safe to remove.
    ///
    /// The typed text is lost. That is the accepted cost of the honest
    /// minimum: a pending/failed state on `Message` is the better product and
    /// is its own slice, because it needs a new field, a migration and
    /// `MessageList` work.
    ///
    /// If the message really did post, the long-poll echo delivers it moments
    /// later and it reappears as a real message - which is strictly better
    /// than a phantom nobody can distinguish from one that arrived.
    ///
    /// `@discardableResult` because most callers cannot act on the answer -
    /// but the auto-mark trigger can, and must: its watermark may only
    /// advance on a real success.
    @discardableResult
    func submit(_ command: ChatCommand, undoing writes: [StoreWrite] = []) async -> Bool {
        guard !suppressed(command) else { return false }
        do {
            try await backend.send(command)
            return true
        } catch {
            // Same reasoning as `requestMoreMessages` and `perform` just below:
            // cancelling this task does not oblige whatever is underneath it to
            // throw `CancellationError`, and a write from a session that no
            // longer owns the store is the exact trap `ChatSessionModel.stop()`
            // cancelling `markTasks` exists to close.
            guard !Task.isCancelled else { return false }
            record(error, undoing: writes)
            return false
        }
    }

    /// The one place ghost mode is enforced.
    ///
    /// **Exhaustive with no `default`, on purpose.** A new `ChatCommand` case
    /// stops this compiling until someone decides whether it says something
    /// about this user that ghost mode should withhold. That compile error is
    /// the guarantee; a two-case `if` would let the next one leak by default.
    /// Same idiom as `SyncReducer.reduce(_:)` and `ConnectionIssueMapping`.
    private func suppressed(_ command: ChatCommand) -> Bool {
        guard ghostMode else { return false }
        switch command {
        case .markRead, .setTyping:
            return true
        case .sendMessage, .editMessage, .deleteMessage, .setReaction,
             .setNotificationLevel, .unknown:
            return false
        }
    }

    /// Fetches a page of history, recording a failure rather than throwing.
    ///
    /// The same contract as `submit(_:)` and for the same reason: the caller
    /// is a view opening a conversation, and a view has nowhere to put a
    /// thrown error. `loadMoreMessages` still throws for callers that can
    /// handle it - the reducer's `.reloadMessages` effect is one - but the
    /// UI path had been swallowing that throw with `try?`, so a dead channel
    /// rendered as an empty transcript with no explanation.
    func requestMoreMessages(in conversation: Conversation.ID, before: Message.ID? = nil) async {
        do {
            try await loadMoreMessages(in: conversation, before: before)
        } catch {
            // A deliberate stop is not a failure - `ChatSessionModel.select(_:)`
            // and `.stop()` both cancel `historyTask` to drop interest in an
            // in-flight fetch. Matching on `CancellationError` here used to be
            // how that was told apart from a real failure, but cancelling a
            // `Task` does not oblige whatever is underneath it to throw
            // Swift's own error: `URLSessionTransport` throws
            // `URLError(.cancelled)`, which `LocalBridgeBackend` then turns
            // into an ordinary-looking `ChatError.transport(...)` -
            // indistinguishable, by type, from a real one. The error's shape
            // is an implementation detail of whatever transport produced it,
            // and a future one could throw something else again.
            //
            // `Task.isCancelled` asks the question that actually matters:
            // did *this* task ask to stop. Recording despite that would
            // itself be a write from a session that no longer owns this
            // store - the same trap `loadMoreMessages`'s own cancellation
            // check exists to close, one layer up. And because this reads
            // our own task rather than the error, a failure that merely
            // *looks* like a cancellation - thrown while nobody here
            // cancelled anything - still falls through to `record` below,
            // exactly as it should.
            guard !Task.isCancelled else { return }
            record(error)
        }
    }
}

// MARK: - The loop

extension SyncEngine {
    func handle(_ event: ChatEvent) async {
        let reduction = SyncReducer.reduce(event)
        do {
            try store.apply(reduction.writes)
        } catch {
            record(error)
        }
        for effect in reduction.effects {
            await perform(effect)
        }
    }

    /// Performs what the reducer could not: the I/O behind a gap.
    func perform(_ effect: SyncEffect) async {
        do {
            switch effect {
            case .reloadConversations:
                try await store.apply([.replaceConversations(backend.loadConversations())])
            case let .reloadMessages(conversation):
                try await loadMoreMessages(in: conversation)
            case let .announceArrival(message):
                announcer.yield(.arrived(message))
            case let .withdrawAnnouncements(conversation, upTo):
                announcer.yield(.read(conversation, upTo: upTo))
            }
        } catch {
            // The same hole `requestMoreMessages` closes, one effect over:
            // `stop()` cancels the consumer task this runs under (see
            // `start()`), and a gap-fill in flight when that happens can
            // throw a cancellation dressed as any error type - see that
            // function's comment for the full reasoning. `Task.isCancelled`
            // names our own cancellation regardless of shape.
            guard !Task.isCancelled else { return }
            record(error)
        }
    }

    /// Puts a failure where the UI can see it. Typed, not rendered: a client
    /// has to tell "sign in again" from "the network hiccuped".
    ///
    /// `undoing` carries any writes that retract what the failed operation had
    /// already claimed. They go in the **same batch** as the error, because
    /// `apply` is one transaction per batch and a window that saw the error
    /// land before the retraction would draw a banner next to the message it
    /// is about to remove.
    func record(_ error: any Error, undoing writes: [StoreWrite] = []) {
        let chatError = error as? ChatError ?? .unknown(String(describing: error))
        try? store.apply(writes + [.setLastError(chatError)])
    }
}
