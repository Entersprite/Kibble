import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ConversationActionLifecycleTests {
    @Test func aHistoryFetchStartedBeforeDeletionCannotRestoreOldMessages() async throws {
        let backend = HangingHistoryBackend()
        let store = try ChatStore.inMemory()
        let id = Conversation.ID("opaque")
        try store.apply([.upsertConversation(Conversation(id: id, kind: .directMessage))])
        let engine = SyncEngine(backend: backend, store: store)
        let fetch = Task { try await engine.loadMoreMessages(in: id) }
        for _ in 0 ..< 400 where await !backend.isHoldingARequest {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHoldingARequest)
        await engine.handle(.conversationRemoved(
            conversationID: id,
            historyBefore: Date(timeIntervalSince1970: 2000)
        ))
        await backend.releaseHungRequest()
        try await fetch.value
        #expect(try store.conversations().isEmpty)
        #expect(try store.messages(in: id).isEmpty)
    }

    @Test func hidingRemainsHiddenAcrossRefreshAndNewActivityRestoresIt() async throws {
        let world = FixtureWorld.minimal
        let backend = FakeBackend(world: world)
        try await backend.connect()
        let conversation = try #require(world.conversations.first)
        let sender = try #require(conversation.members.first { $0 != world.me })
        try await backend.send(.conversationAction(conversationID: conversation.id, action: .hide))
        #expect(try await backend.loadConversations().allSatisfy { $0.id != conversation.id })
        #expect(try await !backend.loadMessages(in: conversation.id, before: nil).isEmpty)
        try await backend.apply(.incomingMessage(
            conversation: conversation.id,
            from: sender,
            text: "new activity",
            thread: nil
        ))
        #expect(try await backend.loadConversations().contains { $0.id == conversation.id })
        await backend.disconnect()
    }

    @Test func migrationPreservesAnExistingConversationAndDefaultsToNoManualMark() throws {
        let database = try DatabaseQueue()
        try Schema.migrator.migrate(database, upTo: "v14")
        try database.write { db in
            try db.execute(sql: """
            INSERT INTO conversation (id, kind, notificationLevel, hasUnread)
            VALUES ('opaque', 'directMessage', 'always', 1)
            """)
        }
        let store = try ChatStore(database)
        let conversation = try #require(try store.conversations().first)
        #expect(conversation.hasUnread)
        #expect(conversation.markedUnreadAt == nil)
    }
}
