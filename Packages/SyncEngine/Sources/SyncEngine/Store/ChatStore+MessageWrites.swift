import ChatKit
import GRDB

extension ChatStore {
    static func advanceConversationActivity(_ message: Message, in db: Database) throws {
        guard !message.isDeleted, try !isClearedHistory(message, in: db) else { return }
        let value = StoredDate.value(message.createdAt)
        try db.execute(
            sql: """
            UPDATE conversation SET lastActivity = ?
            WHERE id = ? AND (lastActivity IS NULL OR lastActivity < ?)
            """,
            arguments: [value, message.conversationID.rawValue, value]
        )
    }

    static func upsertUnclearedMessage(_ message: Message, in db: Database) throws {
        guard try !isClearedHistory(message, in: db) else { return }
        // An optimistic copy and its echo are the same message with two
        // different ids: the client invented one, the server assigned the
        // other. Keyed on `localID`, which the server echoes back and which
        // is `nil` on everyone else's messages - so this can never merge two
        // messages that merely both lack one.
        //
        // The `id <> ?` clause is what keeps an ordinary re-delivery of the
        // same server message from deleting the row it is about to write.
        if let localID = message.localID {
            try db.execute(
                sql: "DELETE FROM message WHERE localID = ? AND id <> ?",
                arguments: [localID, message.id.rawValue]
            )
        }
        let incoming = try MessageRow(message)
        if let stored = try MessageRow.fetchOne(db, key: incoming.id) {
            // Raw columns are the fast path. JSON object ordering is not
            // semantic, so differently encoded collections still compare
            // against the entire domain value before publishing a change.
            if incoming == stored {
                return
            }
            if try stored.message == message {
                return
            }
        }
        try incoming.upsert(db)
    }

    static func insertUnclearedMessageIfAbsent(_ message: Message, in db: Database) throws {
        guard try !isClearedHistory(message, in: db) else { return }
        try MessageRow(message).insert(db, onConflict: .ignore)
    }

    static func setMentionBackfill(_ status: MentionBackfillStatus, in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE syncState SET mentionBackfillRunning = ?, mentionBackfillFailed = ?
            WHERE id = 1 AND (mentionBackfillRunning <> ? OR mentionBackfillFailed <> ?)
            """,
            arguments: [
                status.running,
                status.failedConversations,
                status.running,
                status.failedConversations
            ]
        )
    }
}
