import ChatKit
import Foundation

// MARK: - Threads

/// The thread panel's page, following, and the Threads list (threads spec
/// §4.3). Split from `SyncEngine.swift` for `file_length`, which declares
/// `followedThreadsTask` without `private` for this file.
///
/// **Each write checks cancellation first, as `loadMoreMessages` does**: an
/// answer that arrives after its caller stopped caring (a closed panel, a
/// sign-out) must not land in a store that may already be erased.
public extension SyncEngine {
    /// Fetches one thread, its first message included. A complete listing
    /// also removes server rows that disappeared while this client was away.
    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async throws {
        let snapshot = try await backend.loadThreadSnapshot(thread, in: conversation)
        try Task.checkCancellation()
        guard snapshot.messages.allSatisfy({ $0.conversationID == conversation && $0.threadID == thread })
        else {
            throw ChatError.unknown("Thread listing contains a message from another thread")
        }
        var writes = snapshot.messages.map { StoreWrite.upsertMessage($0) }
        if snapshot.isComplete {
            writes.append(.reconcileThread(
                thread: thread, conversation: conversation,
                keeping: snapshot.messages.map(\.id)
            ))
        }
        try store.apply(writes)
    }

    /// Follows or unfollows a thread, then files the answer itself.
    ///
    /// The write repeats the `.followed` event the backend also emits, on
    /// purpose. That event reaches the store through the event loop some time
    /// after this returns, while the panel's toggle stops waiting the moment
    /// it does, so without this write the toggle would show the old state in
    /// between: the spring-back a request exists to prevent (spec §1).
    func setThreadFollowed(
        _ followed: Bool, thread: MessageThread.ID, in conversation: Conversation.ID
    ) async throws {
        try await backend.setThreadFollowed(followed, thread: thread, in: conversation)
        try Task.checkCancellation()
        try store.apply([
            .applyThreadChange(thread: thread, conversation: conversation, change: .followed(followed))
        ])
    }

    /// Fetches the Threads list and files its messages: each followed
    /// thread's first message and the one reply the answer carries. Followed
    /// state and counts arrive as the backend's own events.
    ///
    /// **Keeping stored reactions**, unlike a history page: whether this
    /// answer carries reactions is not measured `[Verify]`, and a reply
    /// already filed by `loadThread` must not lose its reactions to it.
    func loadFollowedThreads() async throws {
        let answer = try await backend.loadFollowedThreads()
        try Task.checkCancellation()
        try store.apply(answer.map { .upsertMessageKeepingReactions($0) })
    }

    /// `loadThread`, recording a failure rather than throwing, for
    /// `requestMoreMessages`' reason: the caller is a view, which has nowhere
    /// to put a thrown error.
    func requestThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async {
        await recordingFailure { try await loadThread(thread, in: conversation) }
    }

    /// `setThreadFollowed`, recording a failure where the window shows it.
    func requestThreadFollowed(
        _ followed: Bool, thread: MessageThread.ID, in conversation: Conversation.ID
    ) async {
        await recordingFailure { try await setThreadFollowed(followed, thread: thread, in: conversation) }
    }

    /// `loadFollowedThreads`, recording a failure where the window shows it.
    func requestFollowedThreads() async {
        await recordingFailure { try await loadFollowedThreads() }
    }
}

extension SyncEngine {
    /// What every world load starts, pushed (`conversationsChanged`) or
    /// fetched after a gap: the Mentions backfill and, for providers that need
    /// it, the Threads list. A provider whose events keep followed threads
    /// current need not issue a separate list request on each world load.
    func worldLoaded(forceMentionBackfill: Bool = false) {
        startMentionBackfill(force: forceMentionBackfill)
        startFollowedThreadsLoad()
    }

    /// One request, replacing one still in flight, only when the backend
    /// advertises useful list backfill. This `Task.isCancelled` is the event
    /// loop's, for `startMentionBackfill()`'s reason.
    func startFollowedThreadsLoad() {
        guard capabilities.supportsThreads, capabilities.needsFollowedThreadsBackfill,
              !Task.isCancelled else { return }
        followedThreadsTask?.cancel()
        followedThreadsTask = Task { [weak self] in
            await self?.requestFollowedThreads()
        }
    }

    /// Runs `work`, recording a failure rather than throwing it, unless this
    /// task was canceled, whatever shape the cancellation took
    /// (`requestMoreMessages`' reasoning, in full there).
    private func recordingFailure(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            guard !Task.isCancelled else { return }
            record(error)
        }
    }
}
