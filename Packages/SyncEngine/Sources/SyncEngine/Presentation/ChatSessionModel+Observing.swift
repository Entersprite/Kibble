import ChatKit
import ChatPersistence
import Foundation
import GRDB

// MARK: - Observing the store

/// Moved out of `ChatSessionModel.swift` unchanged when the Mentions list
/// took that file to swiftlint's `file_length` ceiling. `watchers`,
/// `directory` and `lastError` are `internal` there for this file's sake,
/// the same trade `+AutoMarkRead.swift` already made for `conversations`.
extension ChatSessionModel {
    /// The directory, observed: one read per member write, never one per
    /// delivery.
    ///
    /// Until session 66 every observation's delivery re-read the whole
    /// `member` table synchronously on the main thread and rebuilt
    /// `directory` from it. That read waits behind the store's serial queue,
    /// which a page of history holds for about 100 ms on a large store (its
    /// seven refetches, `docs/journal/2026-10-10-session-66.md`). With pages
    /// landing back to back, as the mention backfill lands them after every
    /// world load, the main thread stalled for up to a quarter second at a
    /// time: the lag while messages load. A member write is the only thing
    /// that can change a name, so it is the only thing that re-reads them.
    func watchDirectory() {
        watch(store.observeMembers()) { [weak self] in
            self?.directory = Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) })
        }
    }

    /// Who the local user is, and their own availability (set-your-status
    /// spec §4): both session values about you, observed together.
    func watchSelf() {
        watch(store.observeMe()) { [weak self] in self?.me = $0 }
        watch(store.observeAvailability()) { [weak self] in self?.availability = $0 }
    }

    /// `store.observeConversations()`'s handler, moved here from `start()` so
    /// `ChatSessionModel.swift` stays a one-line `watch(...)` call - the same
    /// `file_length` reasoning that put this whole extension in its own file.
    /// This is why `conversations` is `internal(set)` rather than
    /// `private(set)`, same as `isActive`.
    func conversationsObserved(_ conversations: [Conversation]) {
        let panelWasShown = isThreadPanelShown
        let selectionWasListed = self.conversations.contains { $0.id == selected }
        let previousMark = self.conversations.first { $0.id == selected }?.markedUnreadAt
        reconcileSearchVisibility(previous: self.conversations, current: conversations)
        self.conversations = conversations
        if selectedMeetingSeries != nil, let selected,
           !conversations.contains(where: { $0.id == selected }) {
            clearSelection()
        }
        reconcileMeetingSelection()
        if selectionWasListed, let selected,
           !conversations.contains(where: { $0.id == selected }) {
            clearSelection()
        }
        markReadTrace?.conversationsChanged(conversations)
        if let selected, conversations.first(where: { $0.id == selected })?.markedUnreadAt != previousMark {
            markSelectedReadIfNeeded()
        }
        // The world load that turns replies on draws a panel held until now:
        // the thread it shows is marked read then (session 58).
        if !panelWasShown, isThreadPanelShown {
            markOpenThreadReadIfNeeded()
        }
    }

    /// The rest of what `select(_:)` swaps once it has canceled the last
    /// conversation's watchers: who is typing, the `@` list's people, and the
    /// thread summaries the marks read. Moved out of `select(_:)` for
    /// `ChatSessionModel.swift`'s `file_length`.
    ///
    /// **It also closes the thread panel and leaves the Threads list.** A panel
    /// belongs to the conversation it was opened in (threads spec §4.3,
    /// "switching conversation closes the panel").
    func selectionMoved(to id: Conversation.ID) {
        watchConversationActivity()
        stopTyping()
        activity = ConversationActivity()
        closeThread()
        threads.showingList = false
        threads.summaries = [:]
        conversationWatchers
            .append(observe(store.observeActivity(in: id)) { [weak self] in self?.activity = $0 })
        conversationWatchers.append(
            observe(store.observeTypingMembers(in: id)) { [weak self] in self?.typing = $0 }
        )
        conversationWatchers.append(
            observe(store.observeMentionCandidates(in: id)) { [weak self] in self?.mentionCandidates = $0 }
        )
        conversationWatchers.append(
            observe(store.observeThreadSummaries(in: id)) { [weak self] in self?.threads.summaries = $0 }
        )
    }

    /// The Threads list, its badge and the sidebar's dots, for the whole
    /// session (threads spec §4.3), from one observation: two re-ran the same
    /// read of every followed thread on each message write (session 61).
    func watchThreads() {
        watch(store.observeFollowedThreadsOverview(limit: ThreadSessionState.listLimit)) { [weak self] in
            self?.threads.setFollowed($0)
        }
    }

    func watch<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) {
        watchers.append(observe(observation, apply))
    }

    func observe<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await value in observation {
                    // A watcher canceled while a value was already on its way
                    // to the main actor applies nothing. Cancellation ends the
                    // stream only once the loop next asks for a value, and the
                    // stream still hands over what it buffered meanwhile: a
                    // closed thread panel showed a reply written after it closed.
                    guard !Task.isCancelled else { return }
                    apply(value)
                }
            } catch {
                self?.lastError = error as? ChatError ?? .unknown(String(describing: error))
            }
        }
    }
}
