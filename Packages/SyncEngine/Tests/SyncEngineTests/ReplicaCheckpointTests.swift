import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatPersistence

struct ReplicaCheckpointTests {
    @Test func failedCheckpointRollsBackItsDomainWrites() throws {
        let store = try ChatStore.inMemory()
        let initial = ReplicaCheckpoint(account: "account", stream: "stream", sequence: 1)
        _ = try store.applyCheckpointed([], checkpoint: initial)
        try store.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER failCheckpoint BEFORE UPDATE ON replicaCheckpoint
            BEGIN SELECT RAISE(ABORT, 'checkpoint refused'); END;
            """)
        }
        let next = ReplicaCheckpoint(account: "account", stream: "stream", sequence: 2)
        let conversation = Conversation(id: Conversation.ID("one"), kind: .space)
        #expect(throws: (any Error).self) {
            try store.applyCheckpointed([.upsertConversation(conversation)], checkpoint: next)
        }
        #expect(try store.conversations().isEmpty)
        #expect(try store.replicaCheckpoint() == initial)
    }

    @Test func duplicateAndForeignCheckpointCannotOverwriteTheReplica() throws {
        let store = try ChatStore.inMemory()
        let checkpoint = ReplicaCheckpoint(account: "account", stream: "stream", sequence: 10)
        let conversation = Conversation(id: Conversation.ID("one"), kind: .space, title: "Original")
        #expect(try store.applyCheckpointed([.upsertConversation(conversation)], checkpoint: checkpoint))
        #expect(try !store.applyCheckpointed([.replaceConversations([])], checkpoint: checkpoint))
        #expect(try store.conversations().first?.title == "Original")
        let foreign = ReplicaCheckpoint(account: "other", stream: "stream", sequence: 11)
        #expect(throws: (any Error).self) {
            try store.applyCheckpointed([.replaceConversations([])], checkpoint: foreign)
        }
        #expect(try store.conversations().first?.title == "Original")
    }
}
