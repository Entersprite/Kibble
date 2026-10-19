import ChatKit
import ChatRules
import Foundation
import GRDB

package extension ChatStore {
    static func performActivityWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .setScopedTyping(update):
            let args: StatementArguments = [
                update.conversationID.rawValue,
                update.threadID?.rawValue ?? "",
                update.member.rawValue
            ]
            try db.execute(sql: """
            INSERT INTO activityTyping VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(conversationID, threadID, memberID) DO UPDATE
                SET version = excluded.version, isTyping = excluded.isTyping
            WHERE activityTyping.version IS NULL OR excluded.version IS NULL
                OR excluded.version >= activityTyping.version
            """, arguments: args + [update.version, update.isTyping])
            // Retain bounded stop tombstones to reject delayed starts from an older provider version.
            try db.execute(sql: """
            DELETE FROM activityTyping WHERE isTyping = 0 AND rowid NOT IN (
                SELECT rowid FROM activityTyping WHERE isTyping = 0 ORDER BY rowid DESC LIMIT 512
            )
            """)
        case let .setReadReceipts(update):
            try applyReceipts(update, in: db)
        case .clearActivityTyping:
            try db.execute(sql: "DELETE FROM activityTyping")
            try db.execute(sql: "DELETE FROM typing")
        default: break
        }
    }

    private static func applyReceipts(_ update: ReadReceiptUpdate, in db: Database) throws {
        let id = update.conversationID.rawValue
        let removed = try Bool.fetchOne(
            db,
            sql:
            "SELECT isRemoved FROM conversationActionState WHERE id = ?",
            arguments: [id]
        ) ?? false
        guard !removed else { return }
        if let enabled = update.enabled {
            try db.execute(sql: """
            INSERT INTO receiptAvailability VALUES (?, ?)
            ON CONFLICT(conversationID) DO UPDATE SET enabled = excluded.enabled
            WHERE enabled <> excluded.enabled
            """, arguments: [id, enabled])
        }
        let enabled = try Bool.fetchOne(
            db,
            sql:
            "SELECT enabled FROM receiptAvailability WHERE conversationID = ?",
            arguments: [id]
        )
        if enabled == false {
            try db.execute(sql: "DELETE FROM readReceipt WHERE conversationID = ?", arguments: [id])
            return
        }
        for position in update.positions {
            let micros = Int64((position.readThrough.timeIntervalSince1970 * 1_000_000).rounded())
            try db.execute(sql: """
            INSERT INTO readReceipt VALUES (?, ?, ?)
            ON CONFLICT(conversationID, memberID) DO UPDATE SET positionMicros = excluded.positionMicros
            WHERE excluded.positionMicros > readReceipt.positionMicros
            """, arguments: [id, position.member.rawValue, micros])
        }
    }
}

public extension ChatStore {
    func observeActivity(in conversation: Conversation.ID) -> AsyncValueObservation<ConversationActivity> {
        ValueObservation.tracking { db in try Self.fetchActivity(conversation, in: db) }
            .removeDuplicates().snapshotValues(in: database)
    }

    func activity(in conversation: Conversation.ID) throws -> ConversationActivity {
        try database.read { try Self.fetchActivity(conversation, in: $0) }
    }
}

package extension ChatStore {
    static func fetchActivity(
        _ conversation: Conversation.ID,
        in db: Database
    ) throws -> ConversationActivity {
        var activity = ConversationActivity()
        let id = conversation.rawValue
        activity.receiptsEnabled = try Bool.fetchOne(
            db,
            sql:
            "SELECT enabled FROM receiptAvailability WHERE conversationID = ?",
            arguments: [id]
        )
        if activity.receiptsEnabled == true {
            activity.receipts = try Row.fetchAll(
                db,
                sql:
                "SELECT memberID, positionMicros FROM readReceipt WHERE conversationID = ? ORDER BY memberID",
                arguments: [id]
            ).map { row in
                let micros: Int64 = row["positionMicros"]
                return ReadPosition(
                    member: Member.ID(row["memberID"]),
                    readThrough: Date(timeIntervalSince1970: Double(micros) / 1_000_000)
                )
            }
        }
        activity.typing = try Row.fetchAll(
            db,
            sql:
            """
            SELECT threadID, memberID, version FROM activityTyping
            WHERE conversationID = ? AND isTyping = 1 ORDER BY memberID
            """,
            arguments: [id]
        ).map { row in
            let thread: String = row["threadID"]
            return TypingUpdate(
                conversationID: conversation,
                threadID: thread.isEmpty ? nil : MessageThread.ID(thread),
                member: Member.ID(row["memberID"]),
                isTyping: true,
                version: row["version"]
            )
        }
        return activity
    }
}
