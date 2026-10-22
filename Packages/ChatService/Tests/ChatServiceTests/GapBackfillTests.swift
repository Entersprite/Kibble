import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

/// What a gap costs the background refill. A provider that owns checkpoints
/// repairs a gap with its own recovery round, so afterwards only conversations
/// whose activity moved or whose history confidence was withdrawn are fetched
/// again. Without checkpoints the gap is the only repair signal, and every
/// recent conversation is.
@Suite(.timeLimit(.minutes(1)))
struct GapBackfillTests {
    static let first = Conversation.ID("first")
    static let second = Conversation.ID("second")
    static let earlier = ReconciliationBackend.date.addingTimeInterval(-120)

    static func row(_ id: Conversation.ID, title: String? = nil, activity: Date = earlier) -> Conversation {
        Conversation(id: id, kind: .space, title: title ?? id.rawValue, lastActivity: activity)
    }

    static func message(in id: Conversation.ID) -> Message {
        Message(
            id: .init("message-\(id.rawValue)"), conversationID: id, threadID: .init("thread-\(id.rawValue)"),
            sender: .init("peer"), text: "Hello", createdAt: earlier
        )
    }

    static func batch(
        _ id: String, events: [ChatEvent] = [], directory: [Conversation]? = nil,
        invalidatesHistory: Bool = false
    ) -> ProviderEventBatch {
        ProviderEventBatch(
            id: id, events: events, directory: directory.map { ConversationSnapshot(conversations: $0) },
            invalidatesHistory: invalidatesHistory, previousCheckpoint: nil, checkpoint: nil
        )
    }

    @Test func unchangedConversationsAreNotFetchedAgainAfterAGap() async throws {
        let harness = try await settledCheckpointedHarness()
        let cursor = try harness.storage.checkpoint()
        await deliverReconnectGaps(to: harness)
        await harness.backend.deliverBatch(Self.batch("renamed", directory: [
            Self.row(Self.first, title: "Renamed"), Self.row(Self.second)
        ]))
        try await waitForRefill(harness, after: cursor)
        #expect(try harness.storage.conversation(Self.first)?.title == "Renamed")
        #expect(await harness.backend.historyReadsByConversation == [Self.first: 1, Self.second: 1])
        await harness.service.shutdown()
    }

    @Test func onlyAConversationWhoseActivityMovedIsFetchedAfterAGap() async throws {
        let harness = try await settledCheckpointedHarness()
        let cursor = try harness.storage.checkpoint()
        await deliverReconnectGaps(to: harness)
        await harness.backend.deliverBatch(Self.batch("moved", directory: [
            Self.row(Self.first), Self.row(Self.second, activity: ReconciliationBackend.date)
        ]))
        try await waitForRefill(harness, after: cursor)
        #expect(await harness.backend.historyReadsByConversation == [Self.first: 1, Self.second: 2])
        await harness.service.shutdown()
    }

    @Test func aConversationWhoseConfidenceWasWithdrawnIsFetchedAfterAGap() async throws {
        let harness = try await settledCheckpointedHarness()
        let cursor = try harness.storage.checkpoint()
        await deliverReconnectGaps(to: harness)
        await harness.backend.deliverBatch(Self.batch(
            "withdrawn", events: [.conversationHistoryInvalidated([Self.first])]
        ))
        try await waitForRefill(harness, after: cursor)
        #expect(await harness.backend.historyReadsByConversation == [Self.first: 2, Self.second: 1])
        #expect(try confirmedIDs(harness, in: Self.first) == [Self.message(in: Self.first).id])
        await harness.service.shutdown()
    }

    /// Every saved row loses confidence, so re-sending them would confirm
    /// nothing: each recent conversation is fetched and confirmed again.
    @Test func anAccountWideWithdrawalFetchesEveryRecentConversationAgain() async throws {
        let harness = try await settledCheckpointedHarness()
        let cursor = try harness.storage.checkpoint()
        await deliverReconnectGaps(to: harness)
        await harness.backend.deliverBatch(Self.batch("rebased", invalidatesHistory: true))
        try await waitForRefill(harness, after: cursor)
        #expect(await harness.backend.historyReadsByConversation == [Self.first: 2, Self.second: 2])
        for id in [Self.first, Self.second] {
            #expect(try confirmedIDs(harness, in: id) == [Self.message(in: id).id])
        }
        await harness.service.shutdown()
    }

    @Test func withoutCheckpointsAGapStillFetchesEveryRecentConversation() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually {
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return try world == nil && backfill == nil && harness.history().count == 1
        }
        let reads = await harness.backend.historyReads
        let worldReads = await harness.backend.worldReads
        await harness.backend.emit(.gap(scope: .everything, reason: "fixture"))
        try await authEventually { await harness.backend.historyReads == reads + 1 }
        #expect(await harness.backend.worldReads > worldReads)
        #expect(try harness.history().count == 1)
        await harness.service.shutdown()
    }

    /// The initial refill has fetched both conversations once and recorded
    /// their activity.
    private func settledCheckpointedHarness() async throws -> ReconciliationHarness {
        let harness = try await ReconciliationHarness.make(backfill: true, checkpointing: true)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("fixture-connected") }
        for id in [Self.first, Self.second] {
            await harness.backend.setHistory([Self.message(in: id)], in: id)
        }
        await harness.backend.deliverBatch(Self.batch(
            "directory", directory: [Self.row(Self.first), Self.row(Self.second)]
        ))
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        try await authEventually {
            let loaded = try [Self.first, Self.second]
                .allSatisfy { try !confirmedIDs(harness, in: $0).isEmpty }
            let backfill = await runtime.backfill
            return loaded && backfill == nil
        }
        #expect(await harness.backend.historyReadsByConversation == [Self.first: 1, Self.second: 1])
        return harness
    }

    /// A resumed channel reports a gap, and so does the recovery it starts.
    private func deliverReconnectGaps(to harness: ReconciliationHarness) async {
        for id in ["resumed", "recovery"] {
            await harness.backend.deliverBatch(Self.batch(id, events: [.gap(scope: .everything, reason: id)]))
        }
    }

    /// Waits for one whole refill pass after `cursor`. A pass reports when it
    /// starts and when it ends, even when it has nothing to fetch, and passes
    /// never overlap.
    private func waitForRefill(_ harness: ReconciliationHarness, after cursor: ServiceCursor) async throws {
        try await authEventually {
            let page = try harness.storage.readEvents(after: cursor, limit: 256)
            #expect(page.snapshot == nil)
            let reports = page.events.filter { item in
                if case .mentionBackfillChanged = item.event {
                    return true
                }
                return false
            }
            return reports.count >= 2
        }
    }

    private func confirmedIDs(
        _ harness: ReconciliationHarness,
        in id: Conversation.ID
    ) throws -> [Message.ID] {
        try harness.storage.recentHistory(in: id, limit: 10).map(\.id)
    }
}
