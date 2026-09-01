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

    /// What the backend behind this engine can do. Forwarded rather than
    /// copied, so it cannot drift from the thing that enforces it.
    public nonisolated var capabilities: Capabilities {
        backend.capabilities
    }

    public init(backend: any ChatBackend, store: ChatStore) {
        self.backend = backend
        self.store = store
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
    func submit(_ command: ChatCommand) async {
        do {
            try await backend.send(command)
        } catch {
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
            }
        } catch {
            record(error)
        }
    }

    /// Puts a failure where the UI can see it. Typed, not rendered: a client
    /// has to tell "sign in again" from "the network hiccuped".
    func record(_ error: any Error) {
        let chatError = error as? ChatError ?? .unknown(String(describing: error))
        try? store.apply([.setLastError(chatError)])
    }
}
