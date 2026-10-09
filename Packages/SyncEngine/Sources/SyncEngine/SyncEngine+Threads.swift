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
    /// Fetches one thread, its first message included, and files it as a
    /// history page is filed (`upsertMessage`): `list_messages` carries
    /// reactions, which is why the reaction refetch already relies on it.
    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async throws {
        let page = try await backend.loadThread(thread, in: conversation)
        try Task.checkCancellation()
        try store.apply(page.map { .upsertMessage($0) })
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
    /// fetched after a gap: the Mentions backfill and the Threads list.
    /// Loading the list after every world load is what gives the Threads
    /// row's badge a number before the pane is opened (spec §4.3).
    func worldLoaded() {
        startMentionBackfill()
        startFollowedThreadsLoad()
    }

    /// One request, replacing one still in flight, and only on a backend with
    /// threads: any other would refuse it, and the refusal would show as a
    /// banner after every world load. This `Task.isCancelled` is the event
    /// loop's, for `startMentionBackfill()`'s reason.
    ///
    /// **A failure is recorded**, like every request a view makes. The
    /// owner's run sent the bridge's request: 200, two bytes, no thread
    /// (`findings.md` §64.9). Not refused, so nothing is recorded, and empty,
    /// so the list holds only the threads Kibble has seen followed. The web
    /// client's flag-gated filter (`WorldSectionRequest` field 16, §64.6) is
    /// the next `[Verify]`. If a server ever refuses it, each world load
    /// records the error and the events that follow clear it again
    /// (`SyncReducer.supersedingStaleError`); count failures instead, as the
    /// Mentions backfill does, if that happens.
    func startFollowedThreadsLoad() {
        guard capabilities.supportsThreads, !Task.isCancelled else { return }
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
