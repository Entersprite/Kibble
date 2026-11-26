import ChatKit
import ChatPersistence
import Foundation

extension SyncEngine {
    func markInboxMessageRead(_ address: MessageAddress) {
        guard !Task.isCancelled else { return }
        do {
            try store.markInboxMessageRead(address)
        } catch {
            record(error)
        }
    }

    func persistUnreadBulkReads(_ reads: [Conversation.ID: UnreadBulkRead]) throws {
        try Task.checkCancellation()
        try store.saveUnreadBulkReads(reads)
    }

    func bulkReceiptTargets(in id: Conversation.ID, for read: UnreadBulkRead) async -> InboxReadTarget {
        guard !Task.isCancelled,
              let conversation = try? store.conversation(id) else { return InboxReadTarget() }
        let main = await bulkMainReceipt(in: conversation, for: read)
        guard let cutoff = read.pendingReplies, capabilities.supportsThreads, conversation.repliesEnabled,
              !Task.isCancelled else { return InboxReadTarget(main: main) }
        let replies = await bulkThreadReceipts(in: conversation, through: cutoff)
        return InboxReadTarget(main: main, replies: replies)
    }

    private func bulkMainReceipt(in row: Conversation, for read: UnreadBulkRead) async -> Date? {
        guard let cutoff = read.pendingMain, UnreadHistoryBasis(row).hasMainUnread else { return nil }
        if let head = row.latestMainMessageAt, head <= cutoff {
            return head
        }
        if let captured = read.confirmedMain, captured == cutoff {
            return captured
        }
        let page = await requestMoreMessages(in: row.id)
        return page?.lazy
            .filter { !$0.isReply && !$0.id.rawValue.hasPrefix("local/") && $0.createdAt <= cutoff }
            .map(\.createdAt).max() ?? read.confirmedMain
    }

    private func bulkThreadReceipts(
        in row: Conversation,
        through cutoff: Date
    ) async -> [MessageThread.ID: Date] {
        var summaries = (try? store.threadSummaries(in: row.id)) ?? [:]
        if row.hasUnreadThread, !summaries.values.contains(where: \.hasUnread) {
            await requestMoreMessages(in: row.id)
            summaries = (try? store.threadSummaries(in: row.id)) ?? [:]
        }
        var replies: [MessageThread.ID: Date] = [:]
        for summary in summaries.values where summary.hasUnread {
            guard !Task.isCancelled, isConversationCurrent(row.id) else { break }
            do {
                try await loadThread(summary.id, in: row.id)
                let messages = try store.threadMessages(summary.id, in: row.id)
                let newest = messages.lazy.filter {
                    $0.isReply && !$0.id.rawValue.hasPrefix("local/") && $0.createdAt <= cutoff
                }.map(\.createdAt).max()
                replies[summary.id] = newest ?? summary.markedUnreadAt.flatMap { $0 <= cutoff ? $0 : nil }
            } catch {
                guard !Task.isCancelled else { return replies }
                record(error)
            }
        }
        return replies
    }

    func validateUnreadBulkReceipts(
        _ target: InboxReadTarget, in id: Conversation.ID, for read: UnreadBulkRead
    ) -> InboxReadTarget {
        guard !Task.isCancelled, let (record, reopened) = try? store.unreadBulkReceiptState(in: id),
              let current = record else { return InboxReadTarget() }
        let main = current.pendingMain == read.pendingMain ? target.main : nil
        let replies = current.pendingReplies == read.pendingReplies
            ? target.replies.filter { !reopened.contains($0.key) }
            : [:]
        return InboxReadTarget(main: main, replies: replies)
    }

    func reconcileUnreadBulkRead(in id: Conversation.ID, for read: UnreadBulkRead) {
        guard !Task.isCancelled, let row = try? store.conversation(id) else { return }
        do {
            let main = UnreadHistoryBasis(row).hasMainUnread ? nil : read.pendingMain
            let replies = if let cutoff = read.pendingReplies, !row.hasUnreadThread,
                             try !store.threadSummaries(in: id).values.contains(where: \.hasUnread) {
                cutoff as Date?
            } else {
                nil as Date?
            }
            if main != nil || replies != nil {
                try store.finishUnreadBulkRead(in: id, main: main, replies: replies)
            }
        } catch {
            record(error)
        }
    }

    /// Backfill on opening the inbox through the known read boundary.
    /// Replies on the conversation pages seed the known unread threads,
    /// whose full snapshots may contain replies the pages did not carry.
    func loadUnreadHistory(in conversation: Conversation) async throws {
        let me = try store.me()
        var remaining = conversation.unreadCount
        var cursor: Message?
        while true {
            try Task.checkCancellation()
            guard let current = try store.conversation(conversation.id) else { return }
            let basis = UnreadHistoryBasis(current)
            if let cursor {
                guard basis.hasMainUnread,
                      basis.position.map({ cursor.createdAt > $0 }) ?? (remaining > 0) else { break }
            } else if !basis.canLoadHistory {
                break
            }
            let page = try await loadMoreMessages(in: conversation.id, before: cursor?.id)
            let roots = page.filter { message in
                !message.isReply && (cursor.map { message.createdAt < $0.createdAt } ?? true)
            }
            guard let oldest = roots.min(by: { $0.createdAt < $1.createdAt }) else { break }
            remaining -= roots.count { !$0.isDeleted && $0.sender != me }
            cursor = oldest
        }

        guard capabilities.supportsThreads, conversation.repliesEnabled,
              isConversationCurrent(conversation.id) else {
            return
        }
        let summaries = try store.threadSummaries(in: conversation.id)
        for thread in summaries.values where thread.hasUnread {
            try Task.checkCancellation()
            guard isConversationCurrent(conversation.id) else { return }
            try await loadThread(thread.id, in: conversation.id)
        }
    }

    private func isConversationCurrent(_ id: Conversation.ID) -> Bool {
        (try? store.conversation(id)) != nil
    }
}
