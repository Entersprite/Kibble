import ChatKit
import Foundation
import GRDB

/// The `thread` table's writes and the conversation's unread-threads flag
/// (threads spec §4.1). Its own file because `ChatStore.swift` is at its
/// length limit; `perform(_:in:)` routes the two cases here.
///
/// **No `Date` is bound here, only `StoredDate.value(_:)`** (`StoredDate`'s
/// rule): a bound `Date` is GRDB's text, and every comparison in these
/// statements is between REAL seconds.
extension ChatStore {
    static func performThreadWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .applyThreadChange(thread, conversation, change):
            try apply(change, to: thread, in: conversation, db)
        case let .setUnreadThreads(conversation, hasUnread):
            try db.execute(
                sql: "UPDATE conversation SET hasUnreadThread = ? WHERE id = ?",
                arguments: [hasUnread, conversation.rawValue]
            )
        default:
            // `perform(_:in:)` routes only the two cases above here, for
            // `performReadWrite(_:in:)`'s reason.
            break
        }
    }

    private static func apply(
        _ change: ThreadChange, to thread: MessageThread.ID, in conversation: Conversation.ID, _ db: Database
    ) throws {
        switch change {
        case let .counted(messages, unread):
            // Both counts are the server's. `unread == nil` is "this source
            // does not say", so the stored count stays.
            try db.execute(
                sql: """
                INSERT INTO thread (conversationID, id, messageCount, unreadCount) VALUES (?, ?, ?, ?)
                ON CONFLICT(conversationID, id) DO UPDATE SET
                    messageCount = excluded.messageCount,
                    unreadCount = COALESCE(excluded.unreadCount, thread.unreadCount)
                """,
                arguments: [conversation.rawValue, thread.rawValue, messages, unread]
            )
        case let .read(upTo):
            // The later of the two positions: a stale page of history must
            // not move a read back.
            try db.execute(
                sql: """
                INSERT INTO thread (conversationID, id, readPosition) VALUES (?, ?, ?)
                ON CONFLICT(conversationID, id) DO UPDATE SET
                    readPosition = MAX(
                        COALESCE(thread.readPosition, excluded.readPosition), excluded.readPosition
                    )
                """,
                arguments: [conversation.rawValue, thread.rawValue, StoredDate.value(upTo)]
            )
            try zeroUnreadCountIfCovered(thread, in: conversation, db)
        case let .markedUnread(at):
            try set("markedUnreadAt", to: at.map(StoredDate.value), thread: thread, in: conversation, db)
        case let .followed(followed):
            try set("isFollowed", to: followed, thread: thread, in: conversation, db)
        case .unknown:
            break
        }
    }

    /// One column of one thread, upserted. `column` is one of this file's
    /// literals, never input.
    private static func set(
        _ column: String, to value: (any DatabaseValueConvertible)?,
        thread: MessageThread.ID, in conversation: Conversation.ID, _ db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO thread (conversationID, id, \(column)) VALUES (?, ?, ?)
            ON CONFLICT(conversationID, id) DO UPDATE SET \(column) = excluded.\(column)
            """,
            arguments: [conversation.rawValue, thread.rawValue, value]
        )
    }

    /// After a read, the server's unread count becomes 0 once the kept
    /// position covers every stored message someone else sent: only
    /// `createdAt > readPosition` keeps it, so equality is read (`findings.md`
    /// §42.2). Your own replies are not unread to you, and a tombstone has
    /// nothing to read. A count nobody stated stays `NULL`, which leaves
    /// `ThreadUnreadRule`'s fallback in charge. Both sides of that `>` are
    /// REAL seconds, so it holds to the microsecond.
    private static func zeroUnreadCountIfCovered(
        _ thread: MessageThread.ID, in conversation: Conversation.ID, _ db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE thread SET unreadCount = 0
            WHERE conversationID = ? AND id = ? AND unreadCount > 0 AND NOT EXISTS (
                SELECT 1 FROM message
                WHERE message.conversationID = thread.conversationID AND message.threadID = thread.id
                    AND message.isDeleted = 0
                    AND message.sender IS NOT (SELECT localMemberID FROM syncState WHERE id = 1)
                    AND message.createdAt > thread.readPosition
            )
            """,
            arguments: [conversation.rawValue, thread.rawValue]
        )
    }
}
