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
        migrator.registerMigration("v3", migrate: addHasUnread)
        migrator.registerMigration("v4", migrate: addMentions)
        migrator.registerMigration("v5", migrate: storeDatesToTheMicrosecond)
        migrator.registerMigration("v6", migrate: addMemberCount)
        migrator.registerMigration("v7", migrate: addMentionBackfillStatus)
        migrator.registerMigration("v8", migrate: addMemberStatus)
        migrator.registerMigration("v9", migrate: addEmojiRecents)
        migrator.registerMigration("v10", migrate: addLinksAndCards)
        return migrator
    }

    /// `Conversation.memberCount`. Nullable, with no default: a row written
    /// before v6 has no count, and "unknown" is what the header draws nothing
    /// for. A default of 0 would draw "0 members", the bug this removes. The
    /// next world load fills it in.
    private static func addMemberCount(_ db: Database) throws {
        try db.alter(table: "conversation") { table in
            table.add(column: "memberCount", .integer)
        }
    }

    /// The Mentions pane's search status (the mentions-list spec §2, ruling 5).
    /// It sits beside `connectionState` because it is the same kind of claim,
    /// about now, and `clearEphemeralState` resets it. The defaults are what a
    /// store that has never searched says: not searching, nothing failed.
    private static func addMentionBackfillStatus(_ db: Database) throws {
        try db.alter(table: "syncState") { table in
            table.add(column: "mentionBackfillRunning", .boolean).notNull().defaults(to: false)
            table.add(column: "mentionBackfillFailed", .integer).notNull().defaults(to: 0)
        }
    }

    /// The person's recent reactions (reactions spec §3), keyed by
    /// `ReactionChoice.key`. A custom emoji keeps its reference, token
    /// included, so its recent can draw its picture. In the account's store,
    /// so `ChatStore.erase()` takes them with the account. `usedAt` is seconds
    /// since 1970 as a double: it is only ever ordered by.
    private static func addEmojiRecents(_ db: Database) throws {
        try db.create(table: "emojiRecent") { table in
            table.primaryKey("key", .text)
            table.column("emoji", .text).notNull()
            table.column("customEmojiID", .text)
            table.column("shortcode", .text)
            table.column("imageToken", .text)
            table.column("usedAt", .double).notNull()
            table.column("uses", .integer).notNull().defaults(to: 1)
        }
    }

    /// `Member.status`, as JSON. Nullable with no default: a row from before
    /// v8 has no status, which is "nobody told us", and the next poll fills
    /// it in. `clearEphemeralState` drops it at every launch anyway.
    private static func addMemberStatus(_ db: Database) throws {
        try db.alter(table: "member") { table in
            table.add(column: "status", .text)
        }
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

    /// Whether anything is unread, separate from how many.
    ///
    /// `unreadCount` was already here and is useless on its own: Google sends
    /// `unread_message_count` as **zero on every conversation**
    /// (`findings.md` §37.8), so the column has only ever held 0. This one
    /// carries the answer derived from the read position and the newest
    /// message's time instead.
    ///
    /// Defaults to `false` rather than being nullable. A row written before
    /// this migration has no unread information, and the honest reading of
    /// "no information" is not-unread - marking an existing conversation
    /// unread on a schema change would announce activity that never happened.
    /// The next world load overwrites it with a measured value anyway.
    private static func addHasUnread(_ db: Database) throws {
        try db.alter(table: "conversation") { table in
            table.add(column: "hasUnread", .boolean).notNull().defaults(to: false)
        }
    }

    /// Links and app cards (links spec §5). `[]` defaults, so a row written
    /// before v10 reads as having none until history reloads it - which is
    /// expected, not a bug.
    private static func addLinksAndCards(_ db: Database) throws {
        try db.alter(table: "message") { table in
            table.add(column: "links", .text).notNull().defaults(to: "[]")
            table.add(column: "cards", .text).notNull().defaults(to: "[]")
        }
    }

    /// Mentions (the mentions spec, §2). A default of `[]` is what makes every
    /// row written before v4 read as "no mentions" rather than fail to decode.
    private static func addMentions(_ db: Database) throws {
        try db.alter(table: "message") { table in
            table.add(column: "mentions", .text).notNull().defaults(to: "[]")
        }
    }

    /// Every date column, from GRDB's millisecond text to the REAL seconds
    /// `StoredDate` writes, in place.
    ///
    /// Up to v4 each of these held `yyyy-MM-dd HH:mm:ss.SSS`, which is what
    /// cost a mark-read its last microseconds (see `StoredDate`). A column left
    /// as text beside new REAL rows would be worse than truncated: SQLite
    /// orders every number before every text, so a migrated message would
    /// sort after every message written since, silently.
    ///
    /// `strftime('%s')` gives the whole seconds and characters 21-23 are the
    /// milliseconds - the format is fixed-width, and the `.` is character 20.
    /// **Not `julianday()`**: that is a double in days at about 2.46 million,
    /// good to roughly 40 µs, so it would move every converted value.
    ///
    /// **Text only** (`typeof(...) = 'text'`), so the step is idempotent. v4
    /// wrote nothing but this text or NULL, but a value that is already a
    /// number would reach `strftime('%s', <number>)`, which reads it as a
    /// Julian day and answers NULL: `message.createdAt NOT NULL` fails and the
    /// store does not open. A NULL is skipped by the same clause, and stays
    /// NULL rather than becoming the epoch.
    ///
    /// Old rows stay millisecond-rounded, which is all they ever held; the
    /// next page of history or live event that carries them rewrites them at
    /// full precision. The `(conversationID, createdAt)` index needs nothing:
    /// an `UPDATE` maintains it.
    private static func storeDatesToTheMicrosecond(_ db: Database) throws {
        let columns = [
            ("message", "createdAt"),
            ("message", "editedAt"),
            ("conversation", "lastActivity"),
            ("conversation", "lastReadAt")
        ]
        for (table, column) in columns {
            try db.execute(sql: """
            UPDATE \(table)
            SET \(column) = CAST(strftime('%s', \(column)) AS REAL)
                + CAST(substr(\(column), 21, 3) AS REAL) / 1000.0
            WHERE typeof(\(column)) = 'text'
            """)
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
