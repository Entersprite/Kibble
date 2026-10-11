import ChatKit
import Foundation

/// Search's engine half (search spec §3, §1.3).
public extension SyncEngine {
    func searchMessages(_ query: MessageSearchQuery, after cursor: MessageSearchCursor?) async throws
        -> MessageSearchPage {
        try await backend.searchMessages(query, after: cursor)
    }

    /// Makes an opened hit openable, and asks for the history just older than
    /// it. Whether the hit is stored at the end.
    ///
    /// A hit the store holds opens as stored: a hit lacks reactions, the edit
    /// time and app cards (`findings.md` §65.8), so the stored copy is the
    /// better one, and nothing is asked. Otherwise the hit is written as
    /// search found it (`.insertMessageIfAbsent`, so a copy that lands
    /// meanwhile is never replaced), then one page is asked `before:` it, so
    /// the transcript shows what led up to it rather than the hit alone. A
    /// reply's thread is drawn from its root, so a reply keeps paging back,
    /// `before:` the oldest root each page brought, until its root is stored.
    ///
    /// **Never trusts a backend to page.** It stops at `pageLimit` pages, at a
    /// page with no root older than the last cursor (an empty one included),
    /// or once the root is stored. That is what ends it if a backend answers
    /// its newest page whatever it is asked, as the bridge does for a message
    /// it has no time for, and as its server may for any anchor (§65.9). The
    /// root is found by a store query for the thread's first message, never by
    /// an id rule: which id a thread is named after is the backend's business.
    ///
    /// The transcript then holds the newest page and the hit's, with a gap
    /// between them it does not show; there is no scroll-back yet.
    ///
    /// Each page is written as `loadMoreMessages` writes one. Cancellation is
    /// checked around every await and before every write, for the reason
    /// `loadMoreMessages` gives: a canceled open must not write into a store a
    /// sign-out is erasing. The check before each request has no test of its
    /// own: only a synchronous write separates it from the check after the
    /// last answer, so no test can cancel in between.
    func loadHistory(in conversation: Conversation.ID, until hit: Message, pageLimit: Int) async throws
        -> Bool {
        if try store.message(hit.id) != nil {
            return true
        }
        try Task.checkCancellation()
        try store.apply([.insertMessageIfAbsent(hit)])
        var before = hit.id
        var boundary = hit.createdAt
        for _ in 0 ..< pageLimit {
            try Task.checkCancellation()
            let page = try await backend.loadMessages(in: conversation, before: before)
            try Task.checkCancellation()
            try store.apply(page.map { .upsertMessage($0) })
            guard hit.isReply, try !isRootStored(of: hit.threadID, in: conversation) else { break }
            let older = page.filter { !$0.isReply && $0.createdAt < boundary }
            guard let oldest = older.min(by: { $0.createdAt < $1.createdAt }) else { break }
            before = oldest.id
            boundary = oldest.createdAt
        }
        return try store.message(hit.id) != nil
    }

    /// Whether the thread's first message is stored: the root
    /// `ChatSessionModel.firstMessage(of:in:)` scrolls to.
    private func isRootStored(of thread: MessageThread.ID, in conversation: Conversation.ID) throws -> Bool {
        try store.threadMessages(thread, in: conversation).contains { !$0.isReply }
    }

    /// Off the main thread: the store is one serial queue (CLAUDE.md, session 66).
    /// A save canceled by `stop()` writes nothing into the store it erases.
    func recordSearch(_ text: String) {
        guard !Task.isCancelled else { return }
        try? store.recordSearch(text, at: Date())
    }

    func recentSearches(limit: Int) -> [String] {
        (try? store.recentSearches(limit: limit)) ?? []
    }
}
