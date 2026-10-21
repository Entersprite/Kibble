import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct QueryGapTests {
    @Test func aPreGapDirectoryReplyCannotGrantStaleQueryAuthority() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        await harness.backend.holdNextWorld()
        await harness.backend.setSearchMembers([Member(id: .init("old"), kind: .human)], hold: true)
        let query = Task { try await harness.call(SearchPeople(query: "peer")) }
        do {
            try await authEventually { await harness.backend.searchHeld }
            await harness.backend.setSearchMembers([Member(id: .init("current"), kind: .human)])
            await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
            try await authEventually { await harness.backend.worldHeld }
            await harness.backend.releaseSearch()
            #expect(try await query.value.map(\.id) == [.init("current")])
            await harness.backend.releaseWorld()
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseSearch()
            await harness.backend.releaseWorld()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func aPreGapHistoryResultCannotCommitWhileRepairIsStillHeld() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        await harness.backend.holdHistoryQueries()
        let query = Task {
            try await harness.call(LoadMessages(conversationID: ReconciliationBackend.conversation))
        }
        do {
            try await authEventually { await harness.backend.historyReads == 1 }
            var current = ReconciliationBackend.message
            current.text = "Current after continuity loss"
            await harness.backend.replaceHistorySilently([current])
            await harness.backend.emit(.gap(scope: .conversation(current.conversationID), reason: "fixture"))
            // The repair started, but cannot commit and accidentally hide the stale query.
            try await authEventually { await harness.backend.historyReads == 2 }
            await harness.backend.releaseHistoryQuery(1)
            let runtime = try #require(await harness.service.runtimes[harness.record.id])
            try await authEventually {
                let jobs = await runtime.reads.histories.values
                for job in jobs where await job.waitingCount == 2 {
                    return true
                }
                return false
            }
            #expect(await harness.backend.historyReads == 2)
            #expect(try harness.history().isEmpty)
            await harness.backend.releaseAllHistoryQueries()
            let result = try await query.value
            #expect(result.messages.first?.text == current.text)
            #expect(try harness.history().first?.text == current.text)
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query.result
            await harness.service.shutdown()
            throw error
        }
    }

    private func idle(_ harness: ReconciliationHarness) async throws {
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return try world == nil && backfill == nil &&
                harness.storage.conversation(ReconciliationBackend.conversation) != nil
        }
    }
}
