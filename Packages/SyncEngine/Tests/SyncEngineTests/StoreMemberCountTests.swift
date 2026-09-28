import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// `Conversation.memberCount` through the store, and across the v6 migration.
///
/// The count is written by the world load and by nothing else, so the only
/// two things the store can get wrong are losing it and inventing it.
/// Inventing is the one that matters: `nil` means "nobody said", and a row
/// that came back as `0` would draw "0 members", which is the bug this
/// column exists to remove.
struct StoreMemberCountTests {
    private let space = Conversation.ID("space:1")

    @Test func aCountSurvivesTheStore() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([Conversation(id: space, kind: .space, memberCount: 14)])])
        #expect(try store.conversations().first?.memberCount == 14)
    }

    @Test func noCountStaysNoCountRatherThanZero() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([Conversation(id: space, kind: .space)])])
        #expect(try store.conversations().first?.memberCount == nil)
    }

    /// An upsert carrying no count clears the old one. That is deliberate:
    /// every `Conversation` a backend sends is a whole snapshot, and a count
    /// kept from an older one would be a number nobody currently stands behind.
    @Test func anUpsertReplacesTheCountWithWhateverItCarries() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([Conversation(id: space, kind: .space, memberCount: 14)])])
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])
        #expect(try store.conversations().first?.memberCount == nil)
    }

    /// A row written before v6 has no count, and reads back as unknown.
    @Test func aRowFromBeforeV6ReadsAsUnknown() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v5")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversation (id, kind, unreadCount, isMuted, notificationLevel, isThreaded)
            VALUES ('space:1', 'space', 0, 0, 'always', 0)
            """)
        }
        let store = try ChatStore(queue)
        #expect(try store.conversations().first?.memberCount == nil)
    }
}
