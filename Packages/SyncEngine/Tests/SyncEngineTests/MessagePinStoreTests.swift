import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct MessagePinStoreTests {
    private let room = Conversation.ID("room")

    @Test func migrationPreservesExistingMessagesAndDoesNotClassifyText() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v27")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversation(id, kind, notificationLevel) VALUES ('room', 'space', 'always');
            INSERT INTO message(id, conversationID, threadID, sender, text, createdAt)
            VALUES ('message', 'room', 'thread', 'peer', 'Alex pinned a message', 1700000000)
            """)
        }
        let store = try ChatStore(queue)
        #expect(try store.message(.init("message"))?.activity == nil)
        try store.apply([.invalidateMessagePins(room)])
        #expect(try revision(store, room) == 1)
    }

    @Test func activitySurvivesReopeningAndTombstonesClearIt() throws {
        let queue = try DatabaseQueue(); let store = try ChatStore(queue)
        var message = Message(
            id: .init("activity"), conversationID: room, threadID: .init("thread"),
            sender: .init("peer"), text: "", createdAt: .distantPast, activity: .pinnedMessage
        )
        try store.apply([.upsertConversation(.init(id: room, kind: .space)), .upsertMessage(message)])
        for activity in [MessageActivity.pinnedMessage, .unknown("future")] {
            message.activity = activity
            try store.apply([.upsertMessage(message)])
            #expect(try ChatStore(queue).message(message.id)?.activity == activity)
        }
        try store.apply([.markMessageDeleted(id: message.id, in: room)])
        #expect(try store.message(message.id)?.activity == nil)
        message.isDeleted = true
        try store.apply([.upsertMessage(message)])
        #expect(try store.message(message.id)?.activity == nil)
    }

    @Test func invalidationsAreCommittedScopedAndErasedWithTheirConversation() async throws {
        let store = try ChatStore.inMemory(); let other = Conversation.ID("other")
        try store.apply([
            .upsertConversation(.init(id: room, kind: .space)),
            .upsertConversation(.init(id: other, kind: .space))
        ])
        var iterator = store.observeMessagePinRevision(in: room).makeAsyncIterator()
        #expect(try await iterator.next() == 0)
        try store.apply([.invalidateMessagePins(other), .invalidateMessagePins(.init("missing"))])
        #expect(try revision(store, room) == 0)
        try store.apply(SyncReducer.reduce(.messagePinsChanged(room)).writes)
        #expect(try await iterator.next() == 1)
        #expect(try revision(store, other) == 1)
        try store.apply([.replaceConversations([])])
        #expect(try await iterator.next() == 0)
        try store.apply([.upsertConversation(.init(id: room, kind: .space)), .invalidateMessagePins(room)])
        try store.erase()
        #expect(try revision(store, room) == 0)
    }

    @Test func observationUsesAnIndexedRevisionLookupIndependentOfHistorySize() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(.init(id: room, kind: .space))])
        let plan = try store.database.write { db in
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10000)
            INSERT INTO message(id, conversationID, threadID, sender, text, createdAt)
            SELECT 'm'||i, 'room', 'thread'||i, 'peer', 'History', i FROM n
            """)
            return try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN SELECT revision FROM messagePinRevision WHERE conversationID = 'room'
            """).map { $0["detail"] as String }.joined()
        }
        #expect(plan.contains("INDEX") && !plan.contains("SCAN"))
        try store.apply([.invalidateMessagePins(room)])
        #expect(try revision(store, room) == 1)
    }

    @Test func confirmedCollectionsSurviveReopeningWithoutGrantingWriteAuthority() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let message = Message(
            id: .init("pin"),
            conversationID: room,
            threadID: .init("old"),
            sender: .init("peer"),
            text: "Saved pin",
            createdAt: .distantPast
        )
        do {
            let store = try ChatStore(DatabaseQueue(path: path))
            try store.apply([
                .upsertConversation(.init(id: room, kind: .space)),
                .replaceMessagePins(
                    conversation: room,
                    pins: .init(
                        messages: [message],
                        members: [.init(id: .init("peer"), kind: .human, displayName: "Alex")],
                        canModify: true
                    )
                )
            ])
        }
        let reopened = try ChatStore(DatabaseQueue(path: path))
        let saved = try #require(try reopened.cachedMessagePins(in: room))
        #expect(saved.messages == [message])
        #expect(saved.members.first?.displayName == "Alex")
        #expect(!saved.canModify)
        #expect(try reopened.message(message.id) == nil)
        let snapshot = try reopened.readSnapshot(includingHistory: [room]) { _, events in events }
        #expect(snapshot.contains(.messagePinsLoaded(conversationID: room, pins: saved)))
        #expect(try reopened.cachedMessagePins(in: .init("other")) == nil)
        try reopened.apply([.replaceMessagePins(conversation: room, pins: .init())])
        #expect(try reopened.cachedMessagePins(in: room) == PinnedMessages())
        try reopened.apply([.replaceConversations([])])
        #expect(try reopened.cachedMessagePins(in: room) == nil)
        try reopened.erase()
        #expect(try reopened.cachedMessagePins(in: room) == nil)
    }

    @Test func version28UpgradeKeepsTheSavedTranscriptAndInvalidationRevision() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v28")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversation(id, kind, notificationLevel) VALUES ('room', 'space', 'always');
            INSERT INTO messagePinRevision VALUES ('room', 9);
            """)
        }
        let store = try ChatStore(queue)
        #expect(try revision(store, room) == 9)
        #expect(try store.cachedMessagePins(in: room) == nil)
    }

    private func revision(_ store: ChatStore, _ id: Conversation.ID) throws -> Int64 {
        try store.database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM messagePinRevision WHERE conversationID = ?",
                arguments: [id.rawValue]
            ) ?? 0
        }
    }
}
