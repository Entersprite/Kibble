import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

struct CallHistoryTests {
    @Test func migrationPreservesExistingMessagesAndPersistsMetadataAcrossUpdatesAndTombstones() throws {
        let database = try DatabaseQueue()
        try Schema.migrator.migrate(database, upTo: "v26")
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO conversation (id, kind, notificationLevel) VALUES ('one', 'space', 'always');
            INSERT INTO message (id, conversationID, threadID, sender, text, createdAt, callStatus)
            VALUES ('old', 'one', 'thread', 'peer', '', 1700000000, 'started');
            """)
        }
        let store = try ChatStore(database)
        #expect(try store.callHistory().messages.map(\.id.rawValue) == ["old"])
        #expect(try store.message(.init("old"))?.callMetadata == nil)
        var message = sample("new", time: 1_700_000_001)
        message.callMetadata = .init(
            reference: "opaque-reference", joinURL: URL(string: "https://example.test/call"),
            endedAt: Date(timeIntervalSince1970: 1_700_000_010.125)
        )
        try store.apply([.upsertMessage(message)])
        #expect(try ChatStore(database).message(message.id)?.callMetadata == message.callMetadata)
        try store.apply([.markMessageDeleted(id: message.id, in: message.conversationID)])
        #expect(try store.message(message.id)?.callMetadata == nil)
        #expect(try store.callHistory().messages.map(\.id.rawValue) == ["old"])
        message.id = .init("deleted-upsert"); message.isDeleted = true
        try store.apply([.upsertMessage(message)])
        let tombstone = try #require(try store.message(message.id))
        #expect(tombstone.callMetadata == nil && tombstone.callStatus == nil)
    }

    @Test func pagingUsesExactStoredTimeAndAnIDTieBreakAndBindsTheConversationFilter() throws {
        let store = try ChatStore(DatabaseQueue())
        try store.apply([
            .upsertConversation(.init(id: .init("one"), kind: .space)),
            .upsertConversation(.init(id: .init("two"), kind: .space))
        ])
        let messages = [
            sample("a", time: 1_700_000_000.123456), sample("b", time: 1_700_000_000.123456),
            sample("c", time: 1_700_000_000.123457), sample("other", time: 1_700_000_001, in: "two")
        ]
        try store.apply(messages.map(StoreWrite.upsertMessage))
        let first = try store.callHistory(.init(conversationID: .init("one"), limit: 1))
        #expect(first.messages.map(\.id.rawValue) == ["c"])
        let second = try store.callHistory(.init(
            conversationID: .init("one"), cursor: #require(first.nextCursor), limit: 1
        ))
        #expect(second.messages.map(\.id.rawValue) == ["b"])
        let third = try store.callHistory(.init(
            conversationID: .init("one"), cursor: #require(second.nextCursor), limit: 1
        ))
        #expect(third.messages.map(\.id.rawValue) == ["a"] && third.nextCursor == nil)
        #expect(throws: CallHistoryError.self) {
            try store.callHistory(.init(conversationID: .init("two"), cursor: first.nextCursor))
        }
        #expect(try store.callHistory().messages.map(\.id.rawValue) == ["other", "c", "b", "a"])
    }

    @Test func historyConfidenceDeletionAndClearedHistoryApplyToTheCallsQuery() throws {
        let store = try ChatStore(DatabaseQueue())
        try store.apply([
            .upsertConversation(.init(id: .init("one"), kind: .space)),
            .upsertConversation(.init(id: .init("two"), kind: .space)),
            .upsertMessage(sample("one", time: 1_700_000_000)),
            .upsertMessage(sample("two", time: 1_700_000_001, in: "two"))
        ])
        var ordinary = sample("ordinary", time: 1_700_000_002)
        ordinary.callStatus = nil; ordinary.text = "Call started"
        try store.apply([.upsertMessage(ordinary), .invalidateConversationHistory([.init("one")])])
        #expect(try store.callHistory().messages.map(\.id.rawValue) == ["two"])
        try store.apply([.upsertMessage(sample("one", time: 1_700_000_000))])
        #expect(try store.callHistory().messages.count == 2)
        try store.apply([.markMessageDeleted(id: .init("two"), in: .init("two"))])
        #expect(try store.callHistory().messages.map(\.id.rawValue) == ["one"])
        try store.apply([.removeConversation(
            conversation: .init("one"), historyBefore: Date(timeIntervalSince1970: 1_700_000_001)
        )])
        #expect(try store.callHistory().messages.isEmpty)
    }

    private func sample(_ id: String, time: Double, in conversation: String = "one") -> Message {
        Message(
            id: .init(id), conversationID: .init(conversation), threadID: .init("thread"),
            sender: .init("peer"), text: "", createdAt: Date(timeIntervalSince1970: time),
            callStatus: .started
        )
    }
}
