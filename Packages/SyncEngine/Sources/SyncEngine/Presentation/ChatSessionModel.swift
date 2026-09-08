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
    public internal(set) var conversations: [Conversation] = [] // set from +AutoMarkRead.swift
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
    ///
    /// `internal(set)`, not `private(set)`: the setter lives in
    /// `ChatSessionModel+AutoMarkRead.swift`, split out to keep this file
    /// under swiftlint's `file_length` ceiling - see that file's header
    /// comment. The public surface is unchanged: nothing outside this module
    /// can write it either way.
    public internal(set) var isActive = true

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
    /// Advances **only on a successful mark** (see `markSelectedReadIfNeeded`
    /// in `ChatSessionModel+AutoMarkRead.swift`).
    ///
    /// Not `private`: the trigger that reads and writes this lives in that
    /// extension file, in a different source file, so this needs at least
    /// `internal` visibility for it to reach. Still invisible outside this
    /// module.
    var published: [Conversation.ID: Date] = [:]

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
    ///
    /// Not `private` for the same reason as `published` just above: read and
    /// written from `ChatSessionModel+AutoMarkRead.swift`.
    var markTasks: [Conversation.ID: Task<Void, Never>] = [:]

    /// The generation of the mark currently installed in `markTasks`, per
    /// conversation - bumped every time a new mark task is installed, never
    /// reset.
    ///
    /// A completing mark may only clear the `markTasks` entry it itself
    /// installed. Without an identity check, a re-armed mark (a mark that
    /// installs a *second* task for the same conversation from inside its own
    /// completion, because a newer message arrived during its flight) is
    /// vulnerable at both of `markSelectedReadIfNeeded`'s clear sites: the
    /// completing task's `defer` runs *after* it has already installed the
    /// replacement, so an unconditional clear there deletes the replacement's
    /// entry out from under it. That reopens the in-flight guard while the
    /// replacement is still running - a second delivery during the
    /// replacement's own flight then passes the guard and starts a third,
    /// concurrent mark for the same conversation - and it also makes the
    /// replacement uncancellable by `stop()`, since a `Task` no longer
    /// reachable from `markTasks` cannot be found and cancelled: the exact
    /// untracked-`Task`-outliving-the-model exposure this dictionary exists to
    /// close, one level down. Comparing the generation captured at install
    /// time against this dictionary before either clear is what tells "my own
    /// entry" from "someone else's, installed after mine."
    ///
    /// Not `private` for the same reason as `published` and `markTasks`
    /// above: read and written from `ChatSessionModel+AutoMarkRead.swift`.
    var markGeneration: [Conversation.ID: Int] = [:]

    /// The text of a send that was not accepted, and the conversation it was
    /// typed in.
    ///
    /// Both halves, because exposing the text alone is how it ends up in
    /// somebody else's composer: `ChatWindow` keys the composer on the
    /// conversation id precisely so a half-typed line cannot follow the user
    /// to a different person, and a restore that ignored the id would undo
    /// that.
    private var failed: (conversationID: Conversation.ID, text: String)?

    /// The failed text, but only while its own conversation is open.
    public var failedDraft: String? {
        guard let failed, failed.conversationID == selected else { return nil }
        return failed.text
    }

    private let store: ChatStore
    /// Not `private`: `ChatSessionModel+AutoMarkRead.swift`'s trigger submits
    /// through this directly, the same way `select(_:)` and `send(_:)` in
    /// this file already do.
    let engine: SyncEngine
    /// `--probe=markread`'s recorder, `nil` otherwise; read from `+AutoMarkRead.swift`.
    let markReadTrace: MarkReadTraceRecorder?
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

    /// The last connection state this model acted on, so that a repeated
    /// `.connected` delivery does not refetch again. The observation can
    /// deliver the same value more than once - it reports the row, not the
    /// transition - and a refetch per delivery would be one `list_topics` per
    /// database write.
    private var actedOnConnection: ConnectionState?
    public init(
        store: ChatStore, engine: SyncEngine, me: Member.ID? = nil,
        markReadTrace: (any MarkReadTraceSink)? = nil
    ) {
        self.store = store
        self.engine = engine
        self.me = me
        self.markReadTrace = markReadTrace.map(MarkReadTraceRecorder.init(sink:))
    }

    /// Starts syncing and watching. Safe to call once; later calls do nothing.
    public func start() async throws {
        guard watchers.isEmpty else { return }
        watch(store.observeConversations()) { [weak self] in self?.conversationsObserved($0) }
        watch(store.observeConnectionState()) { [weak self] in
            self?.connectionState = $0
            self?.catchUpIfReconnected($0)
        }
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
        // Unreachable today - a fresh model is built per session - but a
        // stale watermark or a retained draft from the account being signed
        // out of must not survive into a model reused for the next sign-in.
        // `markGeneration` is deliberately **not** reset here: see its own
        // doc comment for the ABA a reset would reopen.
        published = [:]
        failed = nil
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

    /// Opens a conversation: swaps the observations over, then fetches a page
    /// of history, because connecting deliberately does not.
    public func select(_ id: Conversation.ID) {
        guard selected != id else { return }
        selected = id
        markReadTrace?.selectionChanged(to: id, in: conversations)
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

    /// Refetches the open conversation's history when the channel comes back.
    ///
    /// A reconnect is a fresh registration with `AID` reset, so messages
    /// delivered during the outage were never seen and no later event will
    /// replay them. The conversation *list* is handled below the seam by
    /// `.gap(scope: .everything)`; this is the half that depends on which
    /// conversation the user has open, which nothing below the seam knows.
    private func catchUpIfReconnected(_ state: ConnectionState) {
        defer { actedOnConnection = state }
        guard case .connected = state else { return }
        if case .connected = actedOnConnection {
            return
        }
        guard let selected else { return }
        // The same task the selection path owns, so a selection change
        // cancels this exactly as it cancels its own fetch - and so that this
        // refetch cannot outlive a selection change of its own, clobbering a
        // fresher fetch's result with an older conversation's history.
        historyTask?.cancel()
        historyTask = Task { [engine] in
            await engine.requestMoreMessages(in: selected)
        }
    }

    /// Called by the host once it has put the text back, so it is not offered
    /// again on the next redraw.
    public func clearFailedDraft() {
        failed = nil
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
        Task { @MainActor [weak self, engine] in
            let accepted = await engine.submit(
                .sendMessage(
                    conversationID: selected, threadID: nil, text: text, localID: localID
                ),
                // By id, not by `localID`. The server echoes `localID` back on
                // the delivered message, so a `localID` retraction would
                // delete the real one whenever the echo beat the failure -
                // which is exactly the `/api/` timeout this whole retraction
                // was written for.
                undoing: undo
            )
            guard let self, !accepted else { return }
            failed = (conversationID: selected, text: text)
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
