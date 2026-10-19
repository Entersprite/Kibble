import ChatKit
import ChatRules
import GRDB

package extension ChatStore {
    static func performMessageRemoval(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .markMessageDeleted(id, _):
            // A tombstone, not a removal: the message keeps its place in the
            // ordering because the protocol keeps sending it and a hole would
            // break paging. A message the store never held is simply not here -
            // it holds pages, not all of history - so this is a no-op then.
            // Its mentions go with its text: a tombstone mentions nobody. And
            // its reactions: a tombstone offers no toggles. Its links and cards
            // go too: a tombstone points nowhere (links spec §5).
            try db.execute(
                sql: """
                UPDATE message SET isDeleted = 1, text = '', mentions = '[]', reactions = '[]',
                                   links = '[]', cards = '[]'
                WHERE id = ? AND (isDeleted <> 1 OR text <> '' OR mentions <> '[]'
                    OR reactions <> '[]' OR links <> '[]' OR cards <> '[]')
                """,
                arguments: [id.rawValue]
            )
            try verifyMessageHistory(id.rawValue, in: db)
        case let .removeMessage(id):
            // Gone, not tombstoned: nothing was ever posted, so there is no
            // place in the ordering to keep.
            //
            // By id, never by `localID`. The server echoes the client's
            // `localID` back onto the delivered message, so a `localID` delete
            // would take the real row whenever the echo beat the failure -
            // which is exactly what a lost response to a POST that landed
            // looks like. A row that is already gone is a no-op, which is what
            // makes this safe in that case rather than merely lucky.
            try db.execute(
                sql: "DELETE FROM message WHERE id = ?",
                arguments: [id.rawValue]
            )
        default: break
        }
    }

    static func updateReactions(_ reactions: [Reaction], message: Message.ID, in db: Database) throws {
        let existing = try String.fetchOne(
            db, sql: "SELECT reactions FROM message WHERE id = ?", arguments: [message.rawValue]
        )
        if let existing, try Wire.value([Reaction].self, from: existing) != reactions {
            try db.execute(
                sql: "UPDATE message SET reactions = ? WHERE id = ?",
                arguments: [Wire.json(reactions), message.rawValue]
            )
        }
    }

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
        // An authoritative upsert retires this exact optimistic identity even
        // if an adapter's canonical ID happens to equal the client's row ID.
        // Client admission creates its pending entry after this write, atomically.
        try db.execute(
            sql: "DELETE FROM messageDelivery WHERE messageID = ?", arguments: [message.id.rawValue]
        )
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
                try verifyMessageHistory(incoming.id, in: db)
                return
            }
            if try stored.message == message {
                try verifyMessageHistory(incoming.id, in: db)
                return
            }
        }
        try incoming.upsert(db)
        try verifyMessageHistory(incoming.id, in: db)
    }

    static func insertUnclearedMessageIfAbsent(_ message: Message, in db: Database) throws {
        guard try !isClearedHistory(message, in: db) else { return }
        try MessageRow(message).insert(db, onConflict: .ignore)
        if db.changesCount > 0 {
            try verifyMessageHistory(message.id.rawValue, in: db)
        }
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
