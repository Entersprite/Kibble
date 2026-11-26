import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ResourceSyncTests {
    @Test func failedBackgroundReadHasScopedHealthAndSuccessClearsOnlyThatFailure() async throws {
        let harness = try await ReconciliationHarness.make()
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually {
            let task = await runtime.worldRefresh
            let reads = await harness.backend.worldReads
            return task == nil && reads > 0
        }
        await harness.backend.failNextWorldReads(10)
        await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
        try await authEventually { await runtime.resourceSync.count == 1 }
        #expect(await runtime.connection == .connected)
        let failed = try await harness.call(ReadEvents(cursor: nil, limit: 256))
        #expect(failed.snapshot?.contains { event in
            guard case let .resourceSyncChanged(status) = event else { return false }
            return status.resource == .directory && status.phase == .failed
        } == true)
        #expect(failed.snapshot?.contains {
            if case .backendError = $0 {
                true
            } else {
                false
            }
        } == false)
        await harness.backend.failNextWorldReads(0)
        _ = try await harness.call(LoadConversations())
        #expect(await runtime.resourceSync.isEmpty)
        await harness.service.shutdown()
    }

    @Test func replacementSnapshotContainsTheAttachedClientsCachedConversationHistory() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        try await authEventually { try harness.history().count == 1 }
        try await harness.hint(.watchConversationActivity(conversationID: ReconciliationBackend.conversation))
        let reads = await harness.backend.historyReads
        let page = try await harness.call(ReadEvents(cursor: nil, limit: 256))
        let history = page.snapshot?.compactMap { event -> MessageHistoryUpdate? in
            guard case let .historyLoaded(update) = event else { return nil }
            return update
        }
        #expect(history?.first?.conversationID == ReconciliationBackend.conversation)
        #expect(history?.first?.messages == [ReconciliationBackend.message])
        #expect(history?.first?.isComplete == false)
        #expect(await harness.backend.historyReads == reads)
        await harness.service.shutdown()
    }
}
