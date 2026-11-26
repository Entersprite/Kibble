import GRDB

extension Schema {
    static func addUnreadBulkReads(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE unreadBulkRead (
            conversationID TEXT NOT NULL PRIMARY KEY REFERENCES conversation(id) ON DELETE CASCADE,
            mainAt REAL, repliesAt REAL, pendingMainAt REAL, pendingRepliesAt REAL, confirmedMainAt REAL
        );
        CREATE TABLE unreadBulkReopenedThread (
            conversationID TEXT NOT NULL REFERENCES unreadBulkRead(conversationID) ON DELETE CASCADE,
            threadID TEXT NOT NULL,
            PRIMARY KEY (conversationID, threadID)
        );
        CREATE TRIGGER reopenBulkConversation AFTER UPDATE OF markedUnreadAt ON conversation
        WHEN NEW.markedUnreadAt IS NOT NULL AND NEW.markedUnreadAt IS NOT OLD.markedUnreadAt
        BEGIN
            UPDATE unreadBulkRead SET mainAt = NULL, pendingMainAt = NULL, confirmedMainAt = NULL
            WHERE conversationID = NEW.id;
        END;
        CREATE TRIGGER reopenBulkThread AFTER UPDATE OF markedUnreadAt ON thread
        WHEN NEW.markedUnreadAt IS NOT NULL AND NEW.markedUnreadAt IS NOT OLD.markedUnreadAt
        BEGIN
            INSERT OR IGNORE INTO unreadBulkReopenedThread
                SELECT conversationID, NEW.id FROM unreadBulkRead
                WHERE conversationID = NEW.conversationID AND repliesAt IS NOT NULL;
        END;
        CREATE TRIGGER confirmBulkConversation AFTER UPDATE OF lastReadAt ON conversation
        WHEN NEW.lastReadAt IS NOT NULL AND NEW.markedUnreadAt IS NULL
        BEGIN
            UPDATE unreadBulkRead SET pendingMainAt = NULL, confirmedMainAt = NULL
            WHERE conversationID = NEW.id AND pendingMainAt IS NOT NULL AND (
                NEW.lastReadAt >= pendingMainAt OR (NEW.hasUnread = 0 AND NEW.unreadCount = 0)
            );
        END;
        CREATE TRIGGER confirmBulkThreads AFTER UPDATE OF hasUnreadThread ON conversation
        WHEN NEW.hasUnreadThread = 0 AND OLD.hasUnreadThread = 1
        BEGIN
            UPDATE unreadBulkRead SET pendingRepliesAt = NULL
            WHERE conversationID = NEW.id AND pendingRepliesAt IS NOT NULL;
        END;
        """)
    }

    static func addUnreadInboxReads(_ db: Database) throws {
        try db.create(table: "unreadInboxRead") { table in
            table.primaryKey("messageID", .text).references("message", column: "id", onDelete: .cascade)
            table.column("conversationID", .text).notNull()
            table.column("threadID", .text)
            table.column("createdAt", .double).notNull()
        }
        try db.create(indexOn: "unreadInboxRead", columns: ["conversationID", "threadID", "createdAt"])
        try db.execute(sql: """
        CREATE TRIGGER reconcileUnreadInboxConversation
        AFTER UPDATE OF lastReadAt, markedUnreadAt ON conversation
        WHEN NEW.lastReadAt IS NOT OLD.lastReadAt OR NEW.markedUnreadAt IS NOT OLD.markedUnreadAt
        BEGIN
            DELETE FROM unreadInboxRead WHERE conversationID = NEW.id AND threadID IS NULL AND (
                (NEW.markedUnreadAt IS NULL AND createdAt <= NEW.lastReadAt)
                OR (NEW.markedUnreadAt IS NOT OLD.markedUnreadAt AND createdAt >= NEW.markedUnreadAt)
                OR (NEW.lastReadAt < OLD.lastReadAt AND createdAt > NEW.lastReadAt)
            );
        END;
        CREATE TRIGGER reconcileUnreadInboxThread
        AFTER UPDATE OF readPosition, markedUnreadAt ON thread
        WHEN NEW.readPosition IS NOT OLD.readPosition OR NEW.markedUnreadAt IS NOT OLD.markedUnreadAt
        BEGIN
            DELETE FROM unreadInboxRead WHERE conversationID = NEW.conversationID AND threadID = NEW.id AND (
                (NEW.markedUnreadAt IS NULL AND createdAt <= NEW.readPosition)
                OR (NEW.markedUnreadAt IS NOT OLD.markedUnreadAt AND createdAt >= NEW.markedUnreadAt)
            );
        END;
        """)
    }
}
