import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// Migration `v13` (threads spec §4.1) on a v12 store with rows in it: the
/// rows survive and read as "not a reply", "replies not enabled" and "no
/// unread threads"; the `thread` table and the thread index exist.
struct StoreThreadMigrationTests {
    private let space = Conversation.ID("space/s")

    /// Filled the way v12 filled it: raw SQL, REAL seconds (`StoredDate`).
    private func v12Store() throws -> ChatStore {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v12")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversation (id, kind, notificationLevel, lastActivity)
            VALUES ('space/s', 'space', 'always', 1790000000.128263)
            """)
            try db.execute(sql: """
            INSERT INTO message (id, conversationID, threadID, sender, text, createdAt)
            VALUES ('m:root', 'space/s', 'topic:1', 'users/alice', 'hi', 1790000000.128263),
                   ('m:old-reply', 'space/s', 'topic:1', 'users/bob', 'on it', 1790000060.5)
            """)
        }
        return try ChatStore(queue)
    }

    /// A reply stored before v13 reads as top-level and stays in the
    /// transcript until history rewrites it (spec §7).
    @Test func aV12StoresRowsSurviveAndReadAsHavingNoThreadState() throws {
        let store = try v12Store()
        let conversation = try #require(try store.conversations().first)
        #expect(conversation.repliesEnabled == false)
        #expect(conversation.hasUnreadThread == false)
        let messages = try store.messages(in: space)
        #expect(messages.map(\.id.rawValue) == ["m:root", "m:old-reply"])
        #expect(messages.allSatisfy { !$0.isReply })
    }

    @Test func theThreadTableAndTheThreadIndexExist() throws {
        let store = try v12Store()
        let indexed = try store.database.read { db in try db.indexes(on: "message").map(\.columns) }
        #expect(indexed.contains(["conversationID", "threadID"]))
        let exists = try store.database.read { db in try db.tableExists("thread") }
        #expect(exists)
    }
}
