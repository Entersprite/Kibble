import ChatKit
import Foundation
import GRDB
import Observation

/// What a window shows, kept in step with the store.
///
/// Lives here rather than in the app target because bridging `ValueObservation`
/// to a view is logic, and CLAUDE.md's rule is that the app is a shell. It
/// imports `Observation`, which is not SwiftUI, so this package still builds
/// anywhere.
///
/// It does import GRDB, for the observation type alone. That keeps the database
/// inside this package: the app target links `ChatStore`, `SyncEngine` and this
/// model, and never sees GRDB in a signature.
///
/// Every property is fed by an observation on the database. Nothing here talks
/// to a backend except through `SyncEngine`, and nothing in a view talks to
/// either.
@MainActor
@Observable
public final class ChatSessionModel {
    public private(set) var conversations: [Conversation] = []
    public private(set) var directory: [Member.ID: Member] = [:]
    public private(set) var messages: [Message] = []
    public private(set) var typing: [Member.ID] = []
    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var lastError: ChatError?
    public private(set) var selected: Conversation.ID?

    /// Who the local user is.
    ///
    /// Fed by `store.observeMe()` in `start()`, the same way `conversations`
    /// and `connectionState` are - `ChatEvent.selfIdentified` is what makes
    /// that possible, where once no event said "this one is you" and the host
    /// had to supply it. `init`'s `me:` parameter is still a starting value,
    /// not deleted: `FakeBackend` already knows its fixture's local user
    /// before `start()` ever reaches the store, and a value the store later
    /// confirms should replace it, not race it to draw first.
    public private(set) var me: Member.ID?

    /// Forwarded from the backend so a view can degrade without meeting one.
    public var capabilities: Capabilities {
        engine.capabilities
    }

    private let store: ChatStore
    private let engine: SyncEngine
    private var watchers: [Task<Void, Never>] = []

    /// Cancelled and replaced whenever the selection changes, so only the open
    /// conversation is observed rather than every conversation ever opened.
    private var conversationWatchers: [Task<Void, Never>] = []

    public init(store: ChatStore, engine: SyncEngine, me: Member.ID? = nil) {
        self.store = store
        self.engine = engine
        self.me = me
    }

    /// Starts syncing and watching. Safe to call once; later calls do nothing.
    public func start() async throws {
        guard watchers.isEmpty else { return }
        watch(store.observeConversations()) { [weak self] in self?.conversations = $0 }
        watch(store.observeConnectionState()) { [weak self] in self?.connectionState = $0 }
        watch(store.observeMe()) { [weak self] in self?.me = $0 }
        try await engine.start()
    }

    public func stop() async {
        for watcher in watchers + conversationWatchers {
            watcher.cancel()
        }
        watchers = []
        conversationWatchers = []
        await engine.stop()
    }

    /// Opens a conversation: swaps the observations over, then fetches a page
    /// of history, because connecting deliberately does not.
    public func select(_ id: Conversation.ID) {
        guard selected != id else { return }
        selected = id
        messages = []
        typing = []

        for watcher in conversationWatchers {
            watcher.cancel()
        }
        conversationWatchers = []
        conversationWatchers.append(
            observe(store.observeMessages(in: id)) { [weak self] in self?.messages = $0 }
        )
        conversationWatchers.append(
            observe(store.observeTypingMembers(in: id)) { [weak self] in self?.typing = $0 }
        )

        Task { [engine] in
            try? await engine.loadMoreMessages(in: id)
        }
    }

    public func send(_ text: String) {
        guard let selected else { return }
        Task { [engine] in
            await engine.submit(
                .sendMessage(conversationID: selected, threadID: nil, text: text, localID: nil)
            )
        }
    }

    /// Members are read once per conversation change rather than observed:
    /// there is one directory for the whole app, it changes rarely, and an
    /// observation per member would be a lot of machinery for a lookup table.
    public func refreshDirectory() {
        directory = Dictionary(
            uniqueKeysWithValues: ((try? store.members()) ?? []).map { ($0.id, $0) }
        )
    }

    private func watch<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) {
        watchers.append(observe(observation, apply))
    }

    private func observe<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await value in observation {
                    apply(value)
                    self?.refreshDirectory()
                }
            } catch {
                self?.lastError = error as? ChatError ?? .unknown(String(describing: error))
            }
        }
    }
}
