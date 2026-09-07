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
    /// The last thing that went wrong, from the store.
    ///
    /// Fed by `store.observeLastError()` in `start()`, like every other
    /// store-backed property. The direct assignment in `observe(_:_:)`'s catch
    /// is the exception and has to be: an observation that has thrown cannot
    /// report itself through the database it just failed to read.
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

    /// Whether the app is frontmost. Fed by the app shell; `true` by default
    /// so every existing construction site and test keeps its behaviour.
    public private(set) var isActive = true

    /// The newest position this session has successfully published, per
    /// conversation.
    ///
    /// **Send-side dedupe, and nothing else.** It exists so a busy
    /// conversation does not produce one `mark_group_readstate` per arriving
    /// message. It never affects what a badge displays - that is always the
    /// server's own `unreadCount` - and it is deliberately not persisted,
    /// because a persisted one would be a local read watermark by another
    /// name, which this design explicitly does not have.
    ///
    /// Advances **only on a successful mark** (see `markSelectedReadIfNeeded`).
    private var published: [Conversation.ID: Date] = [:]

    /// The mark in flight for a conversation, if any, keyed by conversation.
    ///
    /// Doubles as the in-flight guard - a key's presence is what stops two
    /// triggers a few milliseconds apart from both calling - and as
    /// `historyTask`'s exact shape applied per conversation instead of once
    /// for the whole session: tracked so `stop()` can cancel them. An
    /// untracked `Task` here captures `engine` strongly and would otherwise
    /// outlive the model, sending a `mark_group_readstate` for an account
    /// `stopAndEraseStore()` just signed out of and feeding a failure back
    /// into a database already erased - the exact trap `historyTask`'s own
    /// doc comment names.
    private var markTasks: [Conversation.ID: Task<Void, Never>] = [:]

    private let store: ChatStore
    private let engine: SyncEngine
    private var watchers: [Task<Void, Never>] = []

    /// Cancelled and replaced whenever the selection changes, so only the open
    /// conversation is observed rather than every conversation ever opened.
    private var conversationWatchers: [Task<Void, Never>] = []

    /// The one history fetch `select(_:)` has in flight, if any.
    ///
    /// Tracked - and cancelled by `stop()` - rather than left to finish on
    /// its own, because an untracked `Task` here is exactly how a previous
    /// account's message could land in a database `stopAndEraseStore()` has
    /// already erased: open a conversation whose history call hangs, sign
    /// out, and the moment it eventually answers `SyncEngine.loadMoreMessages`
    /// would upsert into a store nothing here still owns. Cancelling does not
    /// promise the underlying network call stops - `stop()` cannot promise
    /// that at this layer - so `loadMoreMessages` itself checks cancellation
    /// again right before it writes; this task is only the signal that
    /// makes that check see `true`.
    private var historyTask: Task<Void, Never>?

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
        // Everything `SyncEngine.record` writes arrives here. Without this
        // watch the property below was only ever set by an observation
        // throwing, so a refused send or a failed history page was recorded
        // and never rendered.
        watch(store.observeLastError()) { [weak self] in self?.lastError = $0 }
        try await engine.start()
    }

    public func stop() async {
        for watcher in watchers + conversationWatchers {
            watcher.cancel()
        }
        watchers = []
        conversationWatchers = []
        // Cancelled, not joined: the request behind it may not itself be
        // abortable, and blocking `stop()` on a hung call would make sign-out
        // hang with it. `SyncEngine.loadMoreMessages`'s own cancellation
        // check is what actually stops it from writing whenever it does
        // return - see `historyTask`'s doc comment.
        historyTask?.cancel()
        historyTask = nil
        // Same reasoning as `historyTask` just above: a mark in flight for an
        // account this call is signing out of must not be left to answer
        // into an erased store.
        for task in markTasks.values {
            task.cancel()
        }
        markTasks = [:]
        await engine.stop()
    }

    /// Stops the sync loop and erases the database behind it - in that
    /// order, and inside one call, so the order is not something a caller has
    /// to get right by its own timing.
    ///
    /// `stop()` already documents that it *awaits* its consuming task rather
    /// than merely cancelling it, so "no further event can reach the store"
    /// is true the instant it returns - which is exactly the guarantee
    /// erasing needs. Calling these two out of order, or from two separate
    /// `await`s a future edit could interleave, would let a write already in
    /// flight from this very session land after the tables are wiped and
    /// repopulate them.
    ///
    /// Used by `AppEnvironment.signOut()`, which explains what "sign out"
    /// does and does not mean.
    public func stopAndEraseStore() async throws {
        await stop()
        try store.erase()
    }

    /// Told by the app shell whether the app is frontmost.
    ///
    /// Becoming frontmost marks the open conversation, because otherwise
    /// everything that arrived while the user was away stays unread until a
    /// *new* message happens to arrive and trigger it.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            markSelectedReadIfNeeded()
        }
    }

    /// Publishes a read position for the open conversation, if all of these
    /// hold: the app is frontmost, the backend can mark read, something is
    /// open, that conversation has a message, its newest position is beyond
    /// what has already been published, and no mark is in flight for it.
    ///
    /// Ghost mode is not checked here. It is enforced in
    /// `SyncEngine.submit(_:)`, which is the single chokepoint by design - a
    /// second check here would be a second place to forget.
    private func markSelectedReadIfNeeded() {
        guard isActive, capabilities.canMarkRead, let selected else { return }
        // `max` rather than `messages.last`, so the trigger does not depend on
        // the observation's ordering.
        guard let newest = messages.map(\.createdAt).max() else { return }
        if let already = published[selected], newest <= already {
            return
        }
        guard markTasks[selected] == nil else { return }
        markTasks[selected] = Task { @MainActor [weak self, engine] in
            // Must be `defer`, not a plain statement after the last use of
            // `self`: any early return added later here - a
            // `Task.checkCancellation()` above `submit`, say - would
            // otherwise leave this conversation's key in `markTasks`
            // forever, wedging every later trigger for it. The badge would
            // then never clear again for the life of the session, which is
            // worse than the bug this task exists to fix.
            defer { self?.markTasks[selected] = nil }
            let accepted = await engine.submit(.markRead(
                conversationID: selected, upTo: newest
            ))
            guard let self, !Task.isCancelled else { return }
            // Only on success, and only if this mark was not cancelled out
            // from under it - `stop()` cancels every entry in `markTasks` on
            // sign-out, and a cancelled mark must not advance the watermark
            // for a conversation that may not even exist in this store any
            // more. A failure leaves the watermark where it was so the next
            // open, the next message or the next return to frontmost tries
            // again - there is no retry loop of its own.
            if accepted {
                published[selected] = newest
            }
            // Cleared here, ahead of the `defer` above, rather than left to
            // it: the recursive re-check just below calls back into
            // `markSelectedReadIfNeeded()`, whose own in-flight guard reads
            // this same dictionary. A `defer` only runs once this closure
            // returns, which is *after* that recursive call already ran - so
            // leaving the clear to `defer` alone made the guard see this
            // conversation as still in flight and silently suppress its own
            // re-check, every time. The `defer` stays, for every early return
            // above this line.
            markTasks[selected] = nil
            // A delivery that arrived while this mark was in flight was
            // suppressed by the `markTasks[selected] == nil` guard above and
            // never re-checked on its own - without this, the last message of
            // a burst is exactly the one that never gets marked, because no
            // later message ever arrives to trigger it again. Re-running the
            // whole check, rather than resubmitting directly, re-validates
            // focus, capability and selection from scratch instead of
            // assuming nothing changed while this awaited. Comparing against
            // a freshly computed newest - not resubmitting unconditionally -
            // is what keeps this from looping forever against a failing
            // backend: on failure `published` stays unadvanced, but the
            // freshly computed newest is unchanged too, so this condition is
            // false and there is no retry loop here.
            if let freshest = messages.map(\.createdAt).max(), freshest > newest {
                markSelectedReadIfNeeded()
            }
        }
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
            observe(store.observeMessages(in: id)) { [weak self] in
                self?.messages = $0
                self?.markSelectedReadIfNeeded()
            }
        )
        conversationWatchers.append(
            observe(store.observeTypingMembers(in: id)) { [weak self] in self?.typing = $0 }
        )

        // Not `try?`. A dead channel, a rejected `/api/` call or a timeout
        // used to leave the transcript reading "No messages" - nothing
        // failed, so nothing was reported, which session 13 §2.2 names as the
        // worst failure shape this project produces. `requestMoreMessages`
        // records instead of throwing, because a view has nowhere to put a
        // thrown error.
        //
        // Cancels whatever `select(_:)` last started, the same as the
        // watchers just above - a history fetch for a conversation nobody is
        // looking at anymore is not worth keeping, and `historyTask` is the
        // one this session's own `stop()` needs to find later.
        historyTask?.cancel()
        historyTask = Task { [engine] in
            await engine.requestMoreMessages(in: id)
        }
    }

    /// Sends, and shows the message immediately.
    ///
    /// The optimistic row carries a `local/`-prefixed id because it has no
    /// server id yet and inventing one that later collides with a real message
    /// id would be worse than an obviously-local one. `ChatStore` replaces it
    /// when the echo arrives, matched on `localID` - see `Message.localID`,
    /// which has documented exactly this since the seam was written.
    ///
    /// A backend that cannot send is not asked. The composer is already hidden
    /// in that case, but a model that wrote an optimistic row anyway would show
    /// a message that never leaves.
    public func send(_ text: String) {
        guard let selected, capabilities.canSendMessages else { return }
        let localID = UUID().uuidString
        // Invented here, and therefore retracted from here. The `local/`
        // prefix is this file's convention and stays this file's business:
        // `ChatStore` deletes a row by id and has never heard of it.
        let optimisticID = Message.ID("local/\(localID)")
        var undo: [StoreWrite] = []
        if let me {
            try? store.apply([.upsertMessage(Message(
                id: optimisticID,
                conversationID: selected,
                threadID: MessageThread.ID(""),
                sender: me,
                text: text,
                createdAt: Date(),
                localID: localID
            ))])
            // Only what was actually written. With no `me` there is no
            // optimistic row and nothing to take back.
            undo = [.removeMessage(id: optimisticID)]
        }
        Task { [engine] in
            await engine.submit(
                .sendMessage(conversationID: selected, threadID: nil, text: text, localID: localID),
                // By id, not by `localID`. The server echoes `localID` back on
                // the delivered message, so a `localID` retraction would
                // delete the real one whenever the echo beat the failure -
                // which is exactly the `/api/` timeout this whole retraction
                // was written for.
                undoing: undo
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
