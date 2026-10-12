import ChatKit
import GRDB

extension ChatStore {
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
        try MessageRow(message).upsert(db)
    }

    static func insertUnclearedMessageIfAbsent(_ message: Message, in db: Database) throws {
        guard try !isClearedHistory(message, in: db) else { return }
        try MessageRow(message).insert(db, onConflict: .ignore)
    }
}
