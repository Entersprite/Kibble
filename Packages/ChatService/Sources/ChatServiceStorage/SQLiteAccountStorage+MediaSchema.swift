import ChatAPI
import Foundation
import GRDB

extension SQLiteAccountStorage {
    static func initializeMediaCatalog(_ db: Database) throws {
        let needsIndex = try !db.tableExists("serviceMediaReference")
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS serviceMediaReference (
            sourceKey BLOB NOT NULL, originKind TEXT NOT NULL, originID TEXT NOT NULL,
            conversationID TEXT NOT NULL, canonical INTEGER NOT NULL,
            messageID TEXT REFERENCES message(id) ON DELETE CASCADE,
            memberID TEXT REFERENCES member(id) ON DELETE CASCADE,
            value BLOB NOT NULL, version TEXT NOT NULL, createdAt REAL NOT NULL,
            expiresAt REAL NOT NULL, touchedAt REAL NOT NULL,
            PRIMARY KEY(sourceKey, originKind, originID, conversationID)
        );
        CREATE INDEX IF NOT EXISTS serviceMediaOrigin ON serviceMediaReference(originKind, originID);
        CREATE INDEX IF NOT EXISTS serviceMediaTouch ON serviceMediaReference(touchedAt);
        CREATE TABLE IF NOT EXISTS serviceMediaMetadata (id INTEGER PRIMARY KEY, entryCount INTEGER NOT NULL);
        INSERT OR IGNORE INTO serviceMediaMetadata SELECT 1, count(*) FROM serviceMediaReference;
        CREATE TRIGGER IF NOT EXISTS serviceMediaInserted AFTER INSERT ON serviceMediaReference
            BEGIN UPDATE serviceMediaMetadata SET entryCount = entryCount + 1 WHERE id = 1; END;
        CREATE TRIGGER IF NOT EXISTS serviceMediaDeleted AFTER DELETE ON serviceMediaReference
            BEGIN UPDATE serviceMediaMetadata SET entryCount = entryCount - 1 WHERE id = 1; END;
        """)
        if needsIndex {
            try db.execute(sql: "UPDATE serviceMediaMetadata SET entryCount = 0 WHERE id = 1")
            let ids = try String.fetchCursor(db, sql: "SELECT id FROM message")
            while let id = try ids.next() {
                do {
                    try indexStoredMedia(id, db: db)
                } catch is DecodingError {
                    // A malformed cached body grants no media access; retain the body for recovery.
                    try db.execute(
                        sql: """
                        DELETE FROM serviceMediaReference WHERE originKind = 'message' AND originID = ?
                        """,
                        arguments: [id]
                    )
                }
            }
            let members = try String.fetchCursor(db, sql: "SELECT id FROM member")
            while let id = try members.next() {
                try indexProfileMedia(id, member: true, db: db)
            }
            let conversations = try String.fetchCursor(db, sql: "SELECT id FROM conversation")
            while let id = try conversations.next() {
                try indexProfileMedia(id, member: false, db: db)
            }
            try trimMediaCatalog(db)
        }
    }

    static func trimMediaCatalog(_ db: Database) throws {
        let count = try Int.fetchOne(db, sql: "SELECT entryCount FROM serviceMediaMetadata WHERE id = 1") ?? 0
        guard count > 50000 else { return }
        try db.execute(sql: """
        DELETE FROM serviceMediaReference WHERE rowid IN (
            SELECT rowid FROM serviceMediaReference ORDER BY touchedAt ASC, rowid ASC LIMIT ?
        )
        """, arguments: [count - 50000])
    }
}
