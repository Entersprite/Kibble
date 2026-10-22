import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

/// A history read a person is waiting for never waits behind background
/// provider work: the background refill, refetches of other chats, or a
/// queued background read of the same history it joins.
@Suite(.timeLimit(.minutes(1)))
struct HistoryPriorityTests {
    let shared = ReconciliationBackend.conversation
    let other = Conversation.ID("other")

    @Test func aClientHistoryReadDoesNotWaitBehindBackgroundProviderWork() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        let base = try await holdBackfill(harness, adding: [other])
        let budget = await harness.service.providerWork
        var query: Task<MessagePage, any Error>?
        do {
            // Background work wants the last slot too: a refetch of another chat.
            await harness.backend.emit(.gap(scope: .conversation(other), reason: "fixture"))
            try await authEventually { await budget.waitingCount == 1 }
            let shared = shared
            query = Task { try await harness.call(LoadMessages(conversationID: shared)) }
            try await authEventually { await harness.backend.historyReads == base + 4 }
            await harness.backend.releaseAllHistoryQueries()
            let page = try #require(await query?.value)
            #expect(page.messages.map(\.id) == [ReconciliationBackend.message.id])
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query?.result
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func aClientThreadReadDoesNotWaitBehindBackgroundProviderWork() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        _ = try await holdBackfill(harness, adding: [other])
        let budget = await harness.service.providerWork
        var query: Task<MessagePage, any Error>?
        do {
            await harness.backend.emit(.gap(scope: .conversation(other), reason: "fixture"))
            try await authEventually { await budget.waitingCount == 1 }
            let thread = LoadThread(threadID: ReconciliationBackend.message.threadID, conversationID: shared)
            query = Task { try await harness.call(thread) }
            try await authEventually { await harness.backend.threadReads == 1 }
            let page = try #require(await query?.value)
            #expect(page.messages.map(\.id) == [ReconciliationBackend.message.id])
            await harness.backend.releaseAllHistoryQueries()
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query?.result
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func aClientJoiningAQueuedBackgroundReadRaisesIt() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        let base = try await holdBackfill(harness)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let budget = await harness.service.providerWork
        var query: Task<MessagePage, any Error>?
        do {
            // The background refetch of this chat queues behind the refill.
            await harness.backend.emit(.gap(scope: .conversation(shared), reason: "fixture"))
            try await authEventually { await budget.waitingCount == 1 }
            let shared = shared
            query = Task { try await harness.call(LoadMessages(conversationID: shared)) }
            // The request joined that read rather than starting its own...
            try await authEventually {
                for job in await runtime.reads.histories.values where await job.waitingCount == 2 {
                    return true
                }
                return false
            }
            // ...and the read it joined went ahead of the background work.
            try await authEventually { await harness.backend.historyReads == base + 4 }
            #expect(await runtime.reads.histories.count == 4)
            await harness.backend.releaseAllHistoryQueries()
            let page = try #require(await query?.value)
            #expect(page.messages.map(\.id) == [ReconciliationBackend.message.id])
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            _ = await query?.result
            await harness.service.shutdown()
            throw error
        }
    }

    /// Withdrawn confidence and a gap in the viewed chat both refetch it.
    @Test(arguments: [false, true])
    func aViewedChatIsRefetchedAheadOfOtherBackgroundRefetches(byGap: Bool) async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        let base = try await holdBackfill(harness, adding: [other])
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let budget = await harness.service.providerWork
        do {
            try await harness.hint(.watchConversationActivity(conversationID: shared))
            try await authEventually {
                await runtime.aggregateClientInterests().conversations.contains(shared)
            }
            // The background refetch lane is busy with another chat, queued behind the refill.
            await harness.backend.emit(.gap(scope: .conversation(other), reason: "fixture"))
            try await authEventually { await budget.waitingCount == 1 }
            await harness.backend.emit(byGap
                ? .gap(scope: .conversation(shared), reason: "fixture")
                : .conversationHistoryInvalidated([shared]))
            try await authEventually { await harness.backend.historyReads == base + 4 }
            await harness.backend.releaseAllHistoryQueries()
            try await authEventually { try !harness.history().isEmpty }
            await harness.service.shutdown()
        } catch {
            await harness.backend.releaseAllHistoryQueries()
            await harness.service.shutdown()
            throw error
        }
    }

    @Test func aCanceledWaiterNoLongerRaisesTheRead() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        let base = try await holdBackfill(harness)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let budget = await harness.service.providerWork
        // Interactive work holds the reserve, so the queued read cannot start yet.
        let reserve = UUID()
        try await budget.acquire(reserve, owner: runtime.instanceID, urgency: WorkUrgency(interactive: true))
        var waiters: [Task<MessagePage, any Error>] = []
        do {
            await harness.backend.emit(.gap(scope: .conversation(shared), reason: "fixture"))
            try await authEventually { await budget.waitingCount == 1 }
            waiters.append(waitForHistory(runtime, backend: harness.backend))
            try await authEventually { await runtime.reads.historyUrgency[shared]?.holders == 2 }
            waiters[0].cancel()
            await #expect(throws: CancellationError.self) { try await waiters[0].value }
            try await authEventually { await runtime.reads.historyUrgency[shared]?.holders == 1 }
            await budget.release(reserve)
            // The read is background work again, and the free slot is the reserve.
            #expect(await budget.waitingCount == 1)
            #expect(await harness.backend.historyReads == base + 3)
            // Control: a person waiting again raises it at once.
            waiters.append(waitForHistory(runtime, backend: harness.backend))
            try await authEventually { await harness.backend.historyReads == base + 4 }
            await harness.backend.releaseAllHistoryQueries()
            _ = try await waiters[1].value
            // Nothing holds an urgency once every read has settled.
            try await authEventually { await runtime.reads.historyUrgency.isEmpty }
            await harness.service.shutdown()
        } catch {
            await budget.release(reserve)
            await harness.backend.releaseAllHistoryQueries()
            for waiter in waiters {
                _ = await waiter.result
            }
            await harness.service.shutdown()
            throw error
        }
    }

    private func waitForHistory(
        _ runtime: AccountRuntime, backend: ReconciliationBackend
    ) -> Task<MessagePage, any Error> {
        let shared = shared
        return Task {
            try await runtime.fetchMessages(
                in: shared, before: nil, backend: backend, epoch: runtime.currentEpoch, interactive: true
            )
        }
    }

    /// After the first refill, holds three background history reads at the
    /// provider: every slot background work may use for this account.
    private func holdBackfill(
        _ harness: ReconciliationHarness, adding conversations: [Conversation.ID] = []
    ) async throws -> Int {
        try await authEventually { try harness.history().count == 1 }
        for id in conversations {
            try await harness.addConversation(id)
        }
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return world == nil && backfill == nil
        }
        let base = await harness.backend.historyReads
        await harness.backend.holdHistoryQueries()
        await harness.backend.addRecentConversations((1 ... 3).map { Conversation.ID("recent-\($0)") })
        try await authEventually { await harness.backend.historyReads == base + 3 }
        return base
    }
}
