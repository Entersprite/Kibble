import ChatKit
import ChatRules
import Foundation
import GRDB

package extension ChatStore {
    static func clearConversationHistory(
        _ id: Conversation.ID,
        through before: Date,
        in db: Database
    ) throws {
        try db.execute(sql: """
        INSERT INTO conversationActionState (id, historyClearedBefore) VALUES (?, ?)
        ON CONFLICT(id) DO UPDATE SET historyClearedBefore =
            MAX(COALESCE(historyClearedBefore, excluded.historyClearedBefore), excluded.historyClearedBefore)
        WHERE historyClearedBefore IS NULL OR historyClearedBefore < excluded.historyClearedBefore
        """, arguments: [id.rawValue, StoredDate.value(before)])
        try db.execute(
            sql: "DELETE FROM message WHERE conversationID = ? AND createdAt <= ?",
            arguments: [id.rawValue, StoredDate.value(before)]
        )
        try db.execute(sql: """
        DELETE FROM thread WHERE conversationID = ? AND NOT EXISTS (
            SELECT 1 FROM message WHERE message.conversationID = thread.conversationID
            AND message.threadID = thread.id
        )
        """, arguments: [id.rawValue])
    }

    static func isClearedHistory(_ message: Message, in db: Database) throws -> Bool {
        guard let cutoff = try Double.fetchOne(
            db,
            sql: "SELECT historyClearedBefore FROM conversationActionState WHERE id = ?",
            arguments: [message.conversationID.rawValue]
        )
        else { return false }
        return StoredDate.value(message.createdAt) <= cutoff
    }

    static func performConversationActionWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .removeConversation(id, before):
            try db.execute(sql: """
            INSERT INTO conversationActionState (id, isRemoved, removedThrough)
            VALUES (?, 1, (SELECT MAX(cutoff) FROM (
                SELECT latestMainMessageAt AS cutoff FROM conversation WHERE id = ?
                UNION ALL SELECT lastActivity AS cutoff FROM conversation WHERE id = ?
                UNION ALL SELECT createdAt AS cutoff FROM message WHERE conversationID = ? AND isReply = 0
                UNION ALL SELECT historyClearedBefore AS cutoff FROM conversationActionState WHERE id = ?
                UNION ALL SELECT removedThrough AS cutoff FROM conversationActionState WHERE id = ?
                UNION ALL SELECT ? AS cutoff
            )))
            ON CONFLICT(id) DO UPDATE SET isRemoved = 1, removedThrough = excluded.removedThrough
            """, arguments: [
                id.rawValue,
                id.rawValue,
                id.rawValue,
                id.rawValue,
                id.rawValue,
                id.rawValue,
                before.map(StoredDate.value)
            ])
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id.rawValue])
            if let before {
                try clearConversationHistory(id, through: before, in: db)
            }
            try db.execute(sql: "DELETE FROM typing WHERE conversationID = ?", arguments: [id.rawValue])
            for table in ["activityTyping", "receiptAvailability", "readReceipt"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE conversationID = ?", arguments: [id.rawValue])
            }
        case let .setConversationUnreadMark(id, at):
            try setConversationUnreadMark(id, at: at, in: db)
        case let .setConversationNotificationSettings(id, level, muted, muteUntil):
            try updateNotificationSettings(id, level: level, muted: muted, muteUntil: muteUntil, in: db)
        default: break
        }
    }

    private static func setConversationUnreadMark(_ id: Conversation.ID, at: Date?, in db: Database) throws {
        // The read position can arrive before the clear. Withdraw the badge
        // when it covers the provider head and no newer root has arrived.
        try db.execute(
            sql: """
            UPDATE conversation
            SET markedUnreadAt = ?, hasUnread = CASE
                WHEN ? IS NOT NULL THEN 1
                WHEN markedUnreadAt IS NOT NULL AND unreadCount = 0
                    AND lastReadAt >= latestMainMessageAt AND NOT EXISTS (
                        SELECT 1 FROM currentMessage AS message
                        WHERE message.conversationID = conversation.id AND message.isReply = 0
                            AND message.createdAt > conversation.lastReadAt
                            AND message.sender IS NOT (SELECT localMemberID FROM syncState WHERE id = 1)
                    ) THEN 0
                ELSE hasUnread END
            WHERE id = ?
            """,
            arguments: [at.map(StoredDate.value), at.map(StoredDate.value), id.rawValue]
        )
    }

    private static func updateNotificationSettings(
        _ id: Conversation.ID, level: NotificationLevel?, muted: Bool?, muteUntil: Date?, in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE conversation SET notificationLevel = COALESCE(?, notificationLevel),
                isMuted = COALESCE(?, isMuted),
                notificationMuteUntil = CASE WHEN ? IS NULL THEN notificationMuteUntil ELSE ? END
                WHERE id = ?
            """,
            arguments: [
                level.map(Wire.string), muted, muted,
                muted == true ? muteUntil.map(StoredDate.value) : nil, id.rawValue
            ]
        )
    }
}

public extension ChatStore {
    func hasManualUnreadMark(in id: Conversation.ID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT markedUnreadAt IS NOT NULL FROM conversation WHERE id = ?",
                arguments: [id.rawValue]
            ) ?? false
        }
    }
}

package extension ChatStore {
    static func mayRestoreConversation(_ conversation: Conversation, in db: Database) throws -> Bool {
        guard let row = try Row
            .fetchOne(
                db,
                sql: "SELECT isRemoved, removedThrough FROM conversationActionState WHERE id = ?",
                arguments: [conversation.id.rawValue]
            ),
            row["isRemoved"] as Bool else { return true }
        guard let through: Double = row["removedThrough"],
              let latest = conversation.latestMainMessageAt else { return false }
        return StoredDate.value(latest) > through
    }
}

public extension ChatStore {
    func restoreConversationForArrival(_ message: Message) throws -> Bool {
        guard !message.isReply else { return false }
        return try database.write { db in
            guard let row = try Row
                .fetchOne(
                    db,
                    sql: "SELECT isRemoved, removedThrough FROM conversationActionState WHERE id = ?",
                    arguments: [message.conversationID.rawValue]
                ),
                row["isRemoved"] as Bool,
                let through: Double = row["removedThrough"], StoredDate.value(message.createdAt) > through,
                try !Self.isClearedHistory(message, in: db) else { return false }
            try db.execute(
                sql: "UPDATE conversationActionState SET isRemoved = 0 WHERE id = ?",
                arguments: [message.conversationID.rawValue]
            )
            return true
        }
    }
}
