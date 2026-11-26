import ChatAPI
import ChatKit
import ChatRules
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage: ServiceNotificationStorage {
    static func initializeNotificationTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS serviceNotificationState (
            id INTEGER PRIMARY KEY CHECK(id = 1), sequence INTEGER NOT NULL DEFAULT 0,
            floor INTEGER NOT NULL DEFAULT 0, count INTEGER NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0
        );
        INSERT OR IGNORE INTO serviceNotificationState(id) VALUES(1);
        CREATE TABLE IF NOT EXISTS serviceNotification (
            sequence INTEGER PRIMARY KEY, conversation TEXT NOT NULL, message TEXT, position REAL
        );
        CREATE TABLE IF NOT EXISTS serviceNotificationDevice (
            id TEXT PRIMARY KEY, acknowledged INTEGER NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS serviceNotificationInsert AFTER INSERT ON serviceNotification BEGIN
            UPDATE serviceNotificationState SET count = count + 1,
                bytes = bytes + length(CAST(NEW.conversation AS BLOB)) +
                    COALESCE(length(CAST(NEW.message AS BLOB)), 0) + 32 WHERE id = 1;
        END;
        CREATE TRIGGER IF NOT EXISTS serviceNotificationDelete AFTER DELETE ON serviceNotification BEGIN
            UPDATE serviceNotificationState SET count = count - 1,
                bytes = bytes - length(CAST(OLD.conversation AS BLOB)) -
                    COALESCE(length(CAST(OLD.message AS BLOB)), 0) - 32 WHERE id = 1;
        END;
        """)
    }

    static func appendNotifications(_ event: ChatEvent, live: Bool, known: Bool, db: Database) throws {
        for effect in SyncReducer.reduce(event).effects {
            switch effect {
            case let .announceArrival(message) where live && !known && !message.isDeleted:
                try insertNotification(message.conversationID, message: message.id, position: nil, db: db)
            case let .withdrawAnnouncements(conversation, position):
                try insertNotification(conversation, message: nil, position: position, db: db)
            default: break
            }
        }
    }

    private static func insertNotification(
        _ conversation: Conversation.ID, message: Message.ID?, position: Date?, db: Database
    ) throws {
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT sequence FROM serviceNotificationState WHERE id = 1"
        ) ?? 0
        guard current < Int64.max else { throw ServiceFailure.overloaded }
        try db.execute(sql: "UPDATE serviceNotificationState SET sequence = sequence + 1 WHERE id = 1")
        try db.execute(sql: "INSERT INTO serviceNotification VALUES(?, ?, ?, ?)", arguments: [
            current + 1, conversation.rawValue, message?.rawValue, position?.timeIntervalSince1970
        ])
        while try Bool.fetchOne(db, sql: """
        SELECT count > 512 OR bytes > 8388608 FROM serviceNotificationState WHERE id = 1
        """) == true {
            guard let first = try Int64.fetchOne(db, sql: "SELECT MIN(sequence) FROM serviceNotification")
            else { throw ServiceFailure.internalFailure }
            try db.execute(sql: "DELETE FROM serviceNotification WHERE sequence = ?", arguments: [first])
            try db.execute(
                sql: "UPDATE serviceNotificationState SET floor = ? WHERE id = 1",
                arguments: [first]
            )
        }
    }

    public func initializeNotifications(for device: ServiceDeviceID) throws {
        guard !device.rawValue.isEmpty, device.rawValue.utf8.count <= 128 else {
            throw ServiceFailure.invalidRequest
        }
        try database.write { db in
            if try Int.fetchOne(
                db,
                sql: "SELECT acknowledged FROM serviceNotificationDevice WHERE id = ?",
                arguments: [device.rawValue]
            ) != nil {
                return
            }
            guard try (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM serviceNotificationDevice") ?? 0) < 64
            else {
                throw ServiceFailure.overloaded
            }
            try db.execute(sql: """
            INSERT INTO serviceNotificationDevice(id, acknowledged)
                SELECT ?, sequence FROM serviceNotificationState WHERE id = 1
            """, arguments: [device.rawValue])
        }
    }

    public func notifications(for device: ServiceDeviceID) throws -> ServiceNotificationPage {
        try database.read { db in
            guard let acknowledged = try Int64.fetchOne(
                db, sql: "SELECT acknowledged FROM serviceNotificationDevice WHERE id = ?",
                arguments: [device.rawValue]
            ), let state = try Row.fetchOne(db, sql: "SELECT * FROM serviceNotificationState WHERE id = 1")
            else { throw ServiceFailure.notAuthorized }
            if acknowledged < state["floor"] as Int64 {
                return ServiceNotificationPage(items: [], checkpoint: state["sequence"], reset: true)
            }
            let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM serviceNotification WHERE sequence > ? ORDER BY sequence LIMIT 32
            """, arguments: [acknowledged])
            let items = rows.map { row in ServiceNotificationItem(
                sequence: row["sequence"], conversation: .init(row["conversation"] as String),
                message: (row["message"] as String?).map { Message.ID($0) },
                readPosition: (row["position"] as Double?).map(Date.init(timeIntervalSince1970:))
            ) }
            return ServiceNotificationPage(
                items: items,
                checkpoint: items.last?.sequence ?? acknowledged,
                reset: false
            )
        }
    }

    public func acknowledgeNotifications(for device: ServiceDeviceID, through sequence: Int64) throws {
        try database.write { db in
            guard sequence >= 0,
                  try sequence <= (Int64.fetchOne(
                      db,
                      sql: "SELECT sequence FROM serviceNotificationState WHERE id = 1"
                  ) ?? 0)
            else { throw ServiceFailure.invalidRequest }
            try db.execute(sql: """
            UPDATE serviceNotificationDevice SET acknowledged = MAX(acknowledged, ?) WHERE id = ?
            """, arguments: [sequence, device.rawValue])
            guard db.changesCount == 1 else { throw ServiceFailure.notAuthorized }
        }
    }

    public func notificationFacts(_ id: Message.ID) throws -> ServiceNotificationFacts? {
        guard let message = try projection.message(id), !message.isDeleted,
              let conversation = try projection.conversation(message.conversationID) else { return nil }
        let thread = message.isReply ? try projection
            .thread(message.threadID, in: message.conversationID) : nil
        let read = message.isReply ? thread?.readPosition : conversation.readPosition
        if let read, read >= message.createdAt {
            return nil
        }
        let me = try projection.me()
        let ids = Set(conversation.members.prefix(14)).union([message.sender]).union(me.map { [$0] } ?? [])
        return try ServiceNotificationFacts(
            message: message, conversation: conversation, members: projection.members(identifiedBy: ids),
            me: me, thread: thread
        )
    }
}
