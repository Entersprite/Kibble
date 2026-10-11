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
    /// For a reply, its thread's first stored message, which the transcript
    /// scrolls to: `nil` for a root, and for a reply whose root is not
    /// stored.
    let threadRoot: Message.ID?
}

extension SyncEngine {
    /// Makes an opened hit openable, asks for the history just older than
    /// it, and reads what the opener lands on: `nil` only when the hit is not
    /// stored at the end.
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
    /// **A page that fails still opens the hit.** Once the hit is stored, the
    /// failure is recorded where errors show, as `requestMoreMessages` records
    /// one, and the hit opens without what led up to it, rather than not at
    /// all. A cancellation is not a failure, for that function's reason: it
    /// throws, and records nothing.
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
        if try store.message(hit.id) == nil {
            try Task.checkCancellation()
            try store.apply([.insertMessageIfAbsent(hit)])
            do {
                try await pageBack(in: conversation, until: hit, pageLimit: pageLimit)
            } catch {
                guard !Task.isCancelled else { throw error }
                record(error)
            }
        }
        return try target(hit.id, in: conversation)
    }

    private func pageBack(in conversation: Conversation.ID, until hit: Message, pageLimit: Int) async throws {
        var before = hit.id
        var boundary = hit.createdAt
        for _ in 0 ..< pageLimit {
            try Task.checkCancellation()
            let page = try await backend.loadMessages(in: conversation, before: before)
            try Task.checkCancellation()
            try store.apply(page.map { .upsertMessage($0) })
            guard hit.isReply, try rootID(of: hit.threadID, in: conversation) == nil else { break }
            let older = page.filter { !$0.isReply && $0.createdAt < boundary }
            guard let oldest = older.min(by: { $0.createdAt < $1.createdAt }) else { break }
            before = oldest.id
            boundary = oldest.createdAt
        }
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
