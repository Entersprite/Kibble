import Foundation
import GRDB

/// The database's shape, as migrations.
///
/// A `DatabaseMigrator` rather than a create-if-missing script because this
/// database lives on a user's disk across app versions, and the only honest way
/// to change a shipped schema is a migration that runs once and is never edited
/// afterwards.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createV1)
        migrator.registerMigration("v2", migrate: addLocalMemberID)
        return migrator
    }

    private static func createV1(_ db: Database) throws {
        try createConversationTables(db)
        try createMessageTable(db)
        try createEphemeralTables(db)
    }

    /// Who the local user is, once a backend has said. Its own column rather
    /// than folded into `connectionState` or `lastError`: those are claims
    /// about *now* and `clearEphemeralState` deliberately drops them, while
    /// this is durable - an account signing in stays who it is on the next
    /// launch. Nullable because a store that has never connected has never
    /// been told.
    private static func addLocalMemberID(_ db: Database) throws {
        try db.alter(table: "syncState") { table in
            table.add(column: "localMemberID", .text)
        }
    }

    private static func createConversationTables(_ db: Database) throws {
        try db.create(table: "conversation") { table in
            table.primaryKey("id", .text)
            table.column("kind", .text).notNull()
            table.column("title", .text)
            table.column("avatarURL", .text)
            table.column("lastActivity", .datetime)
            table.column("unreadCount", .integer).notNull().defaults(to: 0)
            table.column("isMuted", .boolean).notNull().defaults(to: false)
            table.column("notificationLevel", .text).notNull()
            table.column("isThreaded", .boolean).notNull().defaults(to: false)
            // Not part of Conversation: the watermark a client sends back when
            // marking read. It belongs beside the conversation, not in the
            // domain model, which is why the model does not carry it.
            table.column("lastReadAt", .datetime)
        }

        try db.create(table: "member") { table in
            table.primaryKey("id", .text)
            table.column("kind", .text).notNull()
            table.column("displayName", .text)
            table.column("email", .text)
            table.column("avatarURL", .text)
            // Nullable and cleared at startup: presence is a claim about now.
            table.column("presence", .text)
        }

        try db.create(table: "conversationMember") { table in
            table.column("conversationID", .text)
                .notNull()
                .references("conversation", onDelete: .cascade)
            table.column("memberID", .text).notNull()
            // The conversation's own order, which is not the table's.
            table.column("position", .integer).notNull()
            table.primaryKey(["conversationID", "memberID"])
        }
    }

    private static func createMessageTable(_ db: Database) throws {
        try db.create(table: "message") { table in
            table.primaryKey("id", .text)
            // Deliberately no foreign key. Messages outlive their conversation
            // leaving the list, and an out-of-order event must not be rejected
            // by the store.
            table.column("conversationID", .text).notNull()
            table.column("threadID", .text).notNull()
            table.column("sender", .text).notNull()
            table.column("text", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("editedAt", .datetime)
            table.column("isDeleted", .boolean).notNull().defaults(to: false)
            // JSON. Always read with their message and never queried across
            // messages, so normalising them would cost two tables and a join on
            // the hottest read in the app.
            table.column("reactions", .text).notNull().defaults(to: "[]")
            table.column("attachments", .text).notNull().defaults(to: "[]")
            table.column("localID", .text)
        }
        try db.create(
            indexOn: "message",
            columns: ["conversationID", "createdAt"]
        )
    }

    private static func createEphemeralTables(_ db: Database) throws {
        try db.create(table: "typing") { table in
            table.column("conversationID", .text).notNull()
            table.column("memberID", .text).notNull()
            table.primaryKey(["conversationID", "memberID"])
        }

        // Exactly one row, enforced rather than assumed.
        try db.create(table: "syncState") { table in
            table.primaryKey("id", .integer)
            table.column("connectionState", .text).notNull()
            table.column("lastError", .text)
            table.check(sql: "id = 1")
        }
        try db.execute(
            sql: "INSERT INTO syncState (id, connectionState) VALUES (1, ?)",
            arguments: [#"{"type":"idle"}"#]
        )
    }
}
