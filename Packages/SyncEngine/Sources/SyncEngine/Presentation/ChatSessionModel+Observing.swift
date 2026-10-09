import ChatKit
import Foundation
import GRDB

// MARK: - Observing the store

/// Moved out of `ChatSessionModel.swift` unchanged when the Mentions list
/// took that file to swiftlint's `file_length` ceiling. `watchers`,
/// `directory` and `lastError` are `internal` there for this file's sake,
/// the same trade `+AutoMarkRead.swift` already made for `conversations`.
extension ChatSessionModel {
    /// Members are read once per conversation change rather than observed:
    /// there is one directory for the whole app, it changes rarely, and an
    /// observation per member would be a lot of machinery for a lookup table.
    public func refreshDirectory() {
        directory = Dictionary(
            uniqueKeysWithValues: ((try? store.members()) ?? []).map { ($0.id, $0) }
        )
    }

    /// Who the local user is, and their own availability (set-your-status
    /// spec §4): both session values about you, observed together.
    func watchSelf() {
        watch(store.observeMe()) { [weak self] in self?.me = $0 }
        watch(store.observeAvailability()) { [weak self] in self?.availability = $0 }
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
        closeThread()
        threads.showingList = false
        threads.summaries = [:]
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
                    self?.refreshDirectory()
                }
            } catch {
                self?.lastError = error as? ChatError ?? .unknown(String(describing: error))
            }
        }
    }
}
