import ChatKit
import Foundation
import GRDB

package struct UnreadBulkRead: Equatable, Sendable {
    package var main: Date?
    package var replies: Date?
    package var pendingMain: Date?
    package var pendingReplies: Date?
    package var confirmedMain: Date?

    package init(
        main: Date? = nil, replies: Date? = nil, pendingMain: Date? = nil,
        pendingReplies: Date? = nil, confirmedMain: Date? = nil
    ) {
        self.main = main
        self.replies = replies
        self.pendingMain = pendingMain
        self.pendingReplies = pendingReplies
        self.confirmedMain = confirmedMain
    }

    package func merging(_ newer: Self) -> Self {
        Self(
            main: [main, newer.main].compactMap(\.self).max(),
            replies: [replies, newer.replies].compactMap(\.self).max(),
            pendingMain: [pendingMain, newer.pendingMain].compactMap(\.self).max(),
            pendingReplies: [pendingReplies, newer.pendingReplies].compactMap(\.self).max(),
            confirmedMain: [confirmedMain, newer.confirmedMain].compactMap(\.self).max()
        )
    }
}

package struct UnreadBulkReadState: Equatable, Sendable {
    package var reads: [Conversation.ID: UnreadBulkRead] = [:]
    package var reopenedThreads: Set<ThreadKey> = []

    package init() {}

    package func covers(_ message: Message) -> Bool {
        let read = reads[message.conversationID]
        if message.isReply {
            let key = ThreadKey(conversation: message.conversationID, thread: message.threadID)
            return !reopenedThreads.contains(key) && (read?.replies.map { message.createdAt <= $0 } ?? false)
        }
        return read?.main.map { message.createdAt <= $0 } ?? false
    }

    package mutating func merge(_ changes: [Conversation.ID: UnreadBulkRead]) {
        for (id, read) in changes {
            reads[id] = (reads[id] ?? UnreadBulkRead()).merging(read)
            if read.replies != nil {
                reopenedThreads = reopenedThreads.filter { $0.conversation != id }
            }
        }
    }
}

package extension ChatStore {
    func observeUnreadBulkReads() -> AsyncValueObservation<UnreadBulkReadState> {
        ValueObservation.tracking(Self.fetchUnreadBulkReads)
            .removeDuplicates()
            .snapshotValues(in: database)
    }

    static func fetchUnreadBulkReads(_ db: Database) throws -> UnreadBulkReadState {
        var state = UnreadBulkReadState()
        for row in try Row.fetchAll(db, sql: "SELECT * FROM unreadBulkRead") {
            let id = Conversation.ID(row["conversationID"])
            state.reads[id] = unreadBulkRead(from: row)
        }
        for row in try Row
            .fetchAll(db, sql: "SELECT conversationID, threadID FROM unreadBulkReopenedThread") {
            state.reopenedThreads.insert(ThreadKey(
                conversation: .init(row["conversationID"]),
                thread: .init(row["threadID"])
            ))
        }
        return state
    }

    func saveUnreadBulkReads(_ reads: [Conversation.ID: UnreadBulkRead]) throws {
        try database.write { db in
            for (id, read) in reads {
                try db.execute(sql: """
                INSERT INTO unreadBulkRead (
                    conversationID, mainAt, repliesAt, pendingMainAt, pendingRepliesAt, confirmedMainAt
                )
                SELECT id, ?, ?, ?, ?, ? FROM conversation WHERE id = ?
                ON CONFLICT(conversationID) DO UPDATE SET
                    mainAt = MAX(COALESCE(mainAt, excluded.mainAt), COALESCE(excluded.mainAt, mainAt)),
                    repliesAt = MAX(
                        COALESCE(repliesAt, excluded.repliesAt), COALESCE(excluded.repliesAt, repliesAt)
                    ),
                    pendingMainAt = MAX(COALESCE(pendingMainAt, excluded.pendingMainAt),
                        COALESCE(excluded.pendingMainAt, pendingMainAt)),
                    pendingRepliesAt = MAX(COALESCE(pendingRepliesAt, excluded.pendingRepliesAt),
                        COALESCE(excluded.pendingRepliesAt, pendingRepliesAt)),
                    confirmedMainAt = MAX(COALESCE(confirmedMainAt, excluded.confirmedMainAt),
                        COALESCE(excluded.confirmedMainAt, confirmedMainAt))
                """, arguments: [
                    read.main.map(StoredDate.value), read.replies.map(StoredDate.value),
                    read.pendingMain.map(StoredDate.value), read.pendingReplies.map(StoredDate.value),
                    read.confirmedMain.map(StoredDate.value), id.rawValue
                ])
                if read.replies != nil {
                    try db.execute(
                        sql: "DELETE FROM unreadBulkReopenedThread WHERE conversationID = ?",
                        arguments: [id.rawValue]
                    )
                }
            }
        }
    }

    func finishUnreadBulkRead(in id: Conversation.ID, main: Date?, replies: Date?) throws {
        try database.write { db in
            try db.execute(sql: """
            UPDATE unreadBulkRead SET
                confirmedMainAt = CASE WHEN pendingMainAt = ? THEN NULL ELSE confirmedMainAt END,
                pendingMainAt = CASE WHEN pendingMainAt = ? THEN NULL ELSE pendingMainAt END,
                pendingRepliesAt = CASE WHEN pendingRepliesAt = ? THEN NULL ELSE pendingRepliesAt END
            WHERE conversationID = ?
            """, arguments: [
                main.map(StoredDate.value),
                main.map(StoredDate.value),
                replies.map(StoredDate.value),
                id.rawValue
            ])
        }
    }

    func unreadBulkReceiptState(in id: Conversation.ID) throws -> (UnreadBulkRead?, Set<MessageThread.ID>) {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM unreadBulkRead WHERE conversationID = ?",
                arguments: [id.rawValue]
            )
            let reopened = try String.fetchAll(db, sql: """
            SELECT threadID FROM unreadBulkReopenedThread WHERE conversationID = ?
            """, arguments: [id.rawValue])
            return (row.map(Self.unreadBulkRead(from:)), Set(reopened.map(MessageThread.ID.init(rawValue:))))
        }
    }

    private static func unreadBulkRead(from row: Row) -> UnreadBulkRead {
        UnreadBulkRead(
            main: (row["mainAt"] as Double?).map(StoredDate.date),
            replies: (row["repliesAt"] as Double?).map(StoredDate.date),
            pendingMain: (row["pendingMainAt"] as Double?).map(StoredDate.date),
            pendingReplies: (row["pendingRepliesAt"] as Double?).map(StoredDate.date),
            confirmedMain: (row["confirmedMainAt"] as Double?).map(StoredDate.date)
        )
    }
}
