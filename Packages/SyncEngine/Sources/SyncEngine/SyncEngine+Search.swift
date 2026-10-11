import ChatKit
import Foundation

/// Search's engine half (search spec §3, §1.3).
public extension SyncEngine {
    func searchMessages(_ query: MessageSearchQuery, after cursor: MessageSearchCursor?) async throws
        -> MessageSearchPage {
        try await backend.searchMessages(query, after: cursor)
    }

    /// Pages a conversation's history back, `before:` the oldest stored
    /// message, until `message` is stored, at most `pageLimit` pages. Whether
    /// it is stored at the end. Each page is written as `loadMoreMessages`
    /// writes one, and cancellation is checked around every await, for the
    /// reason `loadMoreMessages` gives: a canceled open must not write into a
    /// store a sign-out is erasing.
    func loadHistory(in conversation: Conversation.ID, until message: Message.ID, pageLimit: Int) async throws
        -> Bool {
        if try store.message(message) != nil {
            return true
        }
        var before = try store.oldestMessage(in: conversation)?.id
        for _ in 0 ..< pageLimit {
            try Task.checkCancellation()
            let page = try await backend.loadMessages(in: conversation, before: before)
            try Task.checkCancellation()
            try store.apply(page.map { .upsertMessage($0) })
            if try store.message(message) != nil {
                return true
            }
            let oldest = page.filter { !$0.isReply }.min { $0.createdAt < $1.createdAt }?.id
            guard let oldest, oldest != before else { return false }
            before = oldest
        }
        return false
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
