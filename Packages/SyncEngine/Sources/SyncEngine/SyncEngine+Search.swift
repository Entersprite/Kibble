import ChatKit
import Foundation

/// Search's engine half (search spec §3, §1.3).
public extension SyncEngine {
    func searchMessages(_ query: MessageSearchQuery, after cursor: MessageSearchCursor?) async throws
        -> MessageSearchPage {
        try await backend.searchMessages(query, after: cursor)
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

/// What opening a hit lands on, read on the engine, so the opener reads no
/// store on the main thread while history pages land (CLAUDE.md, session 66).
struct HistoryTarget: Sendable, Equatable {
    /// The stored copy, which may be richer than the hit (`findings.md` §65.8).
    let message: Message
    /// For a reply, its thread's first stored non-reply message, which the
    /// transcript scrolls to: `nil` for a root, and for a reply whose root is
    /// not stored.
    let threadRoot: Message.ID?
}

extension SyncEngine {
    /// Asks for the history just older than an opened hit, stores the hit
    /// with it, and reads what the opener lands on: `nil` only when the hit is
    /// not stored at the end.
    ///
    /// **One page is asked `before:` the hit, so the transcript shows what led
    /// up to it rather than the hit alone,** and the hit is written as search
    /// found it in the same write as that page. So an open canceled before its
    /// page lands, by a step to another hit, by ✕ or by `stop()`, stores
    /// nothing, and the next open of that hit asks again. The hit goes in
    /// first, as `.insertMessageIfAbsent`, and the page's upserts after it:
    /// a copy that is already stored, or that the page itself carries, is
    /// never replaced by the hit, which lacks reactions, the edit time and app
    /// cards (`findings.md` §65.8). A reply's thread is drawn from its root, so
    /// a reply keeps paging back, `before:` the oldest root each page brought,
    /// until its root is stored. With a `pageLimit` of zero the hit is stored
    /// alone and nothing is asked.
    ///
    /// **A stored hit opens as stored,** and asks for nothing, when a
    /// top-level message older than it is stored too. One with nothing older
    /// beside it asks for its page as an unstored one does, and the stored
    /// copy still opens: that is what a failed first page leaves, and what an
    /// open that wrote the hit before its page left behind.
    ///
    /// **A page that fails still opens the hit.** The failure is recorded
    /// where errors show, as `requestMoreMessages` records one. If it was the
    /// first page, the hit is then stored alone, and opens without what led up
    /// to it, rather than not at all. A cancellation is not a failure, for
    /// that function's reason: it throws, and records nothing.
    ///
    /// **A store failure before the hit opens is recorded too,** then thrown:
    /// the hit cannot open, and the person is told why rather than shown
    /// nothing. One on a reply's later page is recorded as a page's is, and
    /// the hit opens.
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
        -> HistoryTarget? {
        do {
            if try needsContext(hit, in: conversation) {
                try Task.checkCancellation()
                try await loadContext(in: conversation, until: hit, pageLimit: pageLimit)
            }
            return try target(hit.id, in: conversation)
        } catch {
            // Only the store's failures reach here: `loadContext` records a
            // page's own. A cancellation, whatever its shape, records nothing.
            if !Task.isCancelled {
                record(error)
            }
            throw error
        }
    }

    /// Whether the hit has nothing stored that led up to it: it is not
    /// stored, or no top-level message older than it is.
    private func needsContext(_ hit: Message, in conversation: Conversation.ID) throws -> Bool {
        guard let stored = try store.message(hit.id) else { return true }
        return try !store.hasTopLevelMessage(in: conversation, before: stored.createdAt)
    }

    /// The hit and the page before it in one write, then a reply's way back
    /// to its root. A page's failure is recorded here; a store's is thrown.
    private func loadContext(
        in conversation: Conversation.ID,
        until hit: Message,
        pageLimit: Int
    ) async throws {
        guard pageLimit > 0 else {
            try store.apply([.insertMessageIfAbsent(hit)])
            return
        }
        let first: [Message]
        do {
            first = try await page(in: conversation, before: hit.id)
        } catch {
            guard !Task.isCancelled else { throw error }
            try store.apply([.insertMessageIfAbsent(hit)])
            record(error)
            return
        }
        try store.apply([.insertMessageIfAbsent(hit)] + first.map { .upsertMessage($0) })
        do {
            try await pageBackToRoot(of: hit, in: conversation, from: first, pagesLeft: pageLimit - 1)
        } catch {
            guard !Task.isCancelled else { throw error }
            record(error)
        }
    }

    /// For a reply, the pages after the first, each `before:` the oldest root
    /// the last one brought, until its root is stored.
    private func pageBackToRoot(
        of hit: Message, in conversation: Conversation.ID, from first: [Message], pagesLeft: Int
    ) async throws {
        var last = first
        var boundary = hit.createdAt
        for _ in 0 ..< pagesLeft {
            guard hit.isReply, try rootID(of: hit.threadID, in: conversation) == nil else { return }
            let older = last.filter { !$0.isReply && $0.createdAt < boundary }
            guard let oldest = older.min(by: { $0.createdAt < $1.createdAt }) else { return }
            boundary = oldest.createdAt
            last = try await page(in: conversation, before: oldest.id)
            try store.apply(last.map { .upsertMessage($0) })
        }
    }

    /// One page, with the cancellation checks every page gets.
    private func page(in conversation: Conversation.ID, before: Message.ID) async throws -> [Message] {
        try Task.checkCancellation()
        let page = try await backend.loadMessages(in: conversation, before: before)
        try Task.checkCancellation()
        return page
    }

    private func target(_ id: Message.ID, in conversation: Conversation.ID) throws -> HistoryTarget? {
        guard let message = try store.message(id) else { return nil }
        let root = message.isReply ? try rootID(of: message.threadID, in: conversation) : nil
        return HistoryTarget(message: message, threadRoot: root)
    }

    /// The thread's first stored message: the rule
    /// `ChatSessionModel.firstMessage(of:in:)` scrolls by.
    private func rootID(of thread: MessageThread.ID, in conversation: Conversation.ID) throws -> Message.ID? {
        try store.threadMessages(thread, in: conversation).first { !$0.isReply }?.id
    }
}
