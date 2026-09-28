import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// Migration `v5`: every date column a v4 store wrote as GRDB's text is
/// converted in place to the REAL seconds the records now write.
///
/// Each store here is migrated to `v4` only, filled the way v4 filled it -
/// raw SQL binding a `Date`, which is GRDB's `yyyy-MM-dd HH:mm:ss.SSS` text,
/// exactly what the default record encoding wrote - and then opened as a
/// `ChatStore`, which runs the rest.
struct StoreDateMigrationTests {
    private let space = Conversation.ID("space/s")
    /// On a millisecond: v4 could hold nothing finer.
    private let old = Date(timeIntervalSince1970: 1_790_000_000.128)
    private let later = Date(timeIntervalSince1970: 1_790_000_000.129)

    private func v4Store(_ fill: (Database) throws -> Void) throws -> ChatStore {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v4")
        try queue.write(fill)
        return try ChatStore(queue)
    }

    private func insertV4Conversation(_ db: Database, lastActivity: Date?, lastReadAt: Date?) throws {
        try db.execute(sql: """
        INSERT INTO conversation (id, kind, lastActivity, notificationLevel, lastReadAt)
        VALUES ('space/s', 'space', ?, 'always', ?)
        """, arguments: [lastActivity, lastReadAt])
    }

    private func insertV4Message(_ db: Database, id: String, createdAt: Date, editedAt: Date?) throws {
        try db.execute(sql: """
        INSERT INTO message (id, conversationID, threadID, sender, text, createdAt, editedAt)
        VALUES (?, 'space/s', 't', 'users/alice', 'hi', ?, ?)
        """, arguments: [id, createdAt, editedAt])
    }

    /// The exact microsecond, not merely the millisecond: `julianday()` is a
    /// double in days, good to about 40 µs, and would move every value by a
    /// sub-millisecond amount that a millisecond comparison cannot see.
    @Test func everyV4DateReadsBackToTheSameMillisecond() throws {
        let store = try v4Store { db in
            try insertV4Conversation(db, lastActivity: later, lastReadAt: old)
            try insertV4Message(db, id: "m:1", createdAt: old, editedAt: later)
        }
        let message = try store.messages(in: space).first
        #expect(microseconds(message?.createdAt) == 1_790_000_000_128_000)
        #expect(microseconds(message?.editedAt) == 1_790_000_000_129_000)
        #expect(try microseconds(store.conversations().first?.lastActivity) == 1_790_000_000_129_000)
        #expect(try microseconds(store.lastReadAt(space)) == 1_790_000_000_128_000)
    }

    /// Nullable columns stay NULL rather than becoming the epoch.
    @Test func v4NullDatesStayNull() throws {
        let store = try v4Store { db in
            try insertV4Conversation(db, lastActivity: nil, lastReadAt: nil)
            try insertV4Message(db, id: "m:1", createdAt: old, editedAt: nil)
        }
        #expect(try store.messages(in: space).first?.editedAt == nil)
        #expect(try store.conversations().first?.lastActivity == nil)
        #expect(try store.lastReadAt(space) == nil)
    }

    /// A migrated row and one written afterwards compare as numbers. Left as
    /// text, the migrated row would sort after every new one - SQLite orders
    /// every number before every text - and silently.
    @Test func aMigratedMessageSortsBeforeANewerOneWrittenAfterTheMigration() throws {
        let store = try v4Store { db in
            try insertV4Conversation(db, lastActivity: nil, lastReadAt: nil)
            try insertV4Message(db, id: "m:b-old", createdAt: old, editedAt: nil)
        }
        try store.apply([.upsertMessage(newMessage("m:a-new", at: 1_790_000_000.128263))])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["m:b-old", "m:a-new"])
    }

    @Test func aMigratedMessageSortsAfterAnOlderOneWrittenAfterTheMigration() throws {
        let store = try v4Store { db in
            try insertV4Conversation(db, lastActivity: nil, lastReadAt: nil)
            try insertV4Message(db, id: "m:a-late", createdAt: later, editedAt: nil)
        }
        try store.apply([.upsertMessage(newMessage("m:b-early", at: 1_790_000_000.128263))])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["m:b-early", "m:a-late"])
    }

    private func newMessage(_ id: String, at seconds: TimeInterval) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "hi",
            createdAt: Date(timeIntervalSince1970: seconds)
        )
    }
}
