import ChatAPI
import ChatKit
import Foundation
import GRDB
import Testing
@testable import ChatService
@testable import ChatServiceStorage

@Suite(.timeLimit(.minutes(1)))
struct ProviderCheckpointTests {
    private let first = Data("opaque-one".utf8)
    private let second = Data("opaque-two".utf8)

    @Test func canonicalEventsCheckpointAndJournalCommitTogetherAndDuplicatesDoNotReapply() throws {
        let storage = try makeStorage()
        let batch = ProviderEventBatch(
            id: "one", events: [.messageReceived(ReconciliationBackend.message)],
            previousCheckpoint: nil, checkpoint: first, isLive: true
        )
        let page = try storage.appendProviderBatch(batch, canonicalEvents: batch.events)
        #expect(try storage.providerCheckpoint() == first)
        #expect(page.events.count == 1)
        let cursor = try storage.checkpoint()
        var changed = ReconciliationBackend.message
        changed.text = "Must not overwrite the committed batch"
        let duplicate = try storage.appendProviderBatch(batch, canonicalEvents: [.messageUpdated(changed)])
        #expect(duplicate.events.isEmpty)
        #expect(try storage.checkpoint() == cursor)
        #expect(try storage.recentHistory(in: changed.conversationID, limit: 10).first?.text == "Original")
    }

    @Test func checkpointFailureRollsBackEveryCanonicalWriteAndJournalEntry() throws {
        let storage = try makeStorage()
        let original = ProviderEventBatch(
            id: "one",
            events: [.messageReceived(ReconciliationBackend.message)],
            previousCheckpoint: nil,
            checkpoint: first
        )
        _ = try storage.appendProviderBatch(original, canonicalEvents: original.events)
        try storage.database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER refuseProviderCheckpoint BEFORE UPDATE ON serviceProviderCheckpoint
            BEGIN SELECT RAISE(ABORT, 'fixture checkpoint failure'); END;
            """)
        }
        let before = try storage.checkpoint()
        var edited = ReconciliationBackend.message
        edited.text = "Edited"
        let batch = ProviderEventBatch(
            id: "two",
            events: [.messageUpdated(edited)],
            previousCheckpoint: first,
            checkpoint: second
        )
        #expect(throws: (any Error).self) { try storage.appendProviderBatch(
            batch,
            canonicalEvents: batch.events
        ) }
        #expect(try storage.providerCheckpoint() == first)
        #expect(try storage.checkpoint() == before)
        #expect(try storage.recentHistory(in: edited.conversationID, limit: 10).first?.text == "Original")
    }

    @Test func aWrongPriorCheckpointCannotCommit() throws {
        let storage = try makeStorage()
        let batch = ProviderEventBatch(
            id: "wrong",
            events: [.messageReceived(ReconciliationBackend.message)],
            previousCheckpoint: first,
            checkpoint: second
        )
        #expect(throws: ServiceFailure.resynchronizationRequired) {
            try storage.appendProviderBatch(batch, canonicalEvents: batch.events)
        }
        #expect(try storage.providerCheckpoint() == nil)
        #expect(try storage.recentHistory(in: ReconciliationBackend.conversation, limit: 10).isEmpty)
    }

    @Test func theServiceAcknowledgesOnlyAfterCanonicalCommit() async throws {
        let harness = try await ReconciliationHarness.make(checkpointing: true)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("fixture-connected") }
        let storage = try #require(harness.storage as? any ServiceProviderCheckpointStorage)
        let canonical = harness.storage
        let expected = first
        await harness.backend.observeAcknowledgements { id in
            guard id == "one" else { return }
            #expect((try? storage.providerCheckpoint()) == expected)
            #expect((try? canonical.recentHistory(in: ReconciliationBackend.conversation, limit: 10))
                == [ReconciliationBackend.message])
        }
        let batch = ProviderEventBatch(
            id: "one",
            events: [.messageReceived(ReconciliationBackend.message)],
            previousCheckpoint: nil,
            checkpoint: first,
            isLive: true
        )
        await harness.backend.deliverBatch(batch)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("one") }
        #expect(try storage.providerCheckpoint() == first)
        #expect(try harness.history() == [ReconciliationBackend.message])
        #expect(await harness.backend.resumedCheckpoint == nil)
        await harness.service.shutdown()
    }

    private func makeStorage() throws -> SQLiteAccountStorage {
        let storage = try SQLiteAccountStorage(account: .init("fixture"), path: ":memory:")
        _ = try storage.append(.conversationsChanged([
            Conversation(id: ReconciliationBackend.conversation, kind: .space)
        ]), live: false)
        return storage
    }
}
