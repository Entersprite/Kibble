import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct ReconciliationTests {
    @Test func anEnabledAccountLoadsItsWorldAndMentionsWithoutAClient() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        try await authEventually { try harness.history().count == 1 }
        #expect(try harness.storage.conversations()
            .map(\.id) == [ReconciliationBackend.conversation])
        #expect(await harness.backend.worldReads > 0)
        #expect(await harness.backend.historyReads == 1)
        let events = try harness.storage.readEvents(after: nil, limit: 256)
        #expect(events.snapshot != nil)
        await harness.service.shutdown()
    }

    @Test func aLateWorldQueryCannotRestoreARemovedConversation() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        await harness.backend.holdNextWorld()
        let query = Task { try await harness.call(LoadConversations()) }
        try await authEventually { await harness.backend.worldHeld }
        await harness.backend.removeConversation()
        try await authEventually { try harness.storage.conversations().isEmpty }
        await harness.backend.releaseWorld()
        #expect(try await query.value.isEmpty)
        #expect(try harness.storage.conversations().isEmpty)
        await harness.service.shutdown()
    }

    @Test func aLateHistoryQueryCannotResurrectADeletedMessage() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        _ = try await harness.call(LoadMessages(conversationID: ReconciliationBackend.conversation))
        await harness.backend.holdNextHistory()
        let query = Task {
            try await harness.call(LoadMessages(conversationID: ReconciliationBackend.conversation))
        }
        try await authEventually { await harness.backend.historyHeld }
        await harness.backend.deleteMessage()
        try await authEventually { try harness.history().first?.isDeleted == true }
        await harness.backend.releaseHistory()
        let result = try await query.value
        #expect(result.messages.first?.isDeleted == true)
        #expect(result.checkpoint != nil)
        #expect(try harness.history().first?.isDeleted == true)
        await harness.service.shutdown()
    }

    @Test func conversationGapsRefreshCanonicalHistoryWithoutSubscriptions() async throws {
        let harness = try await ReconciliationHarness.make()
        try await idle(harness)
        #expect(try harness.history().isEmpty)
        await harness.backend.emit(.gap(
            scope: .conversation(ReconciliationBackend.conversation),
            reason: "fixture gap"
        ))
        try await authEventually { try harness.history().count == 1 }
        #expect(await harness.backend.historyReads == 1)
        await harness.service.shutdown()
    }

    @Test func disableDrainsNoncooperativeBackfillAndFencesItsLateResult() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true, holdHistory: true)
        try await authEventually { await harness.backend.historyHeld }
        let disabling = Task { try await harness.call(SetAccountEnabled(enabled: false)) }
        try await authEventually { try harness.registry.accounts().first?.isEnabled == false }
        #expect(try harness.history().isEmpty)
        await harness.backend.releaseHistory()
        #expect(try await disabling.value.isEnabled == false)
        #expect(try harness.history().isEmpty)
        #expect(await harness.service.activeRuntimeCount == 0)
        await harness.service.shutdown()
    }

    @Test func subscriptionHydratesFromCanonicalHistoryWithoutRepeatingProviderReads() async throws {
        let harness = try await ReconciliationHarness.make(backfill: true)
        try await authEventually { try harness.history().count == 1 }
        try await idle(harness)
        let before = await harness.backend.historyReads
        let cursor = try harness.storage.checkpoint()
        let request = try ServiceRequest(header: ServiceRequestHeader(
            requestID: ServiceRequestID("subscribe"), accountID: harness.record.id,
            accountRevision: harness.record.currentRevision
        ), payload: ReadEvents(cursor: nil, limit: 256))
        let context = ServiceSessionContext(
            principalID: harness.record.principalID, deviceID: ServiceDeviceID("device"),
            sessionID: ClientSessionID("client"), accounts: [harness.record.id]
        )
        let stream = try await harness.service.events(ServiceCodec.encode(request), context: context)
        let observed = EventCounter()
        let consumer = Task { for try await bytes in stream {
            let page = try ServiceCodec.decode(ServiceEventPage.self, from: bytes)
            for item in page.events where item.cursor.sequence > cursor.sequence {
                if case .historyLoaded = item.event {
                    await observed.found()
                }
            }
        } }
        try await authEventually { await observed.hasHistory }
        #expect(await harness.backend.historyReads == before)
        consumer.cancel(); _ = await consumer.result
        await harness.service.shutdown()
    }

    private func idle(_ harness: ReconciliationHarness) async throws {
        try await authEventually {
            guard let runtime = await harness.service.runtimes[harness.record.id] else { return false }
            let world = await runtime.worldRefresh
            let backfill = await runtime.backfill
            return try world == nil && backfill == nil &&
                (harness.storage.conversations().count == 1)
        }
    }
}

private actor EventCounter {
    private(set) var hasHistory = false
    func found() {
        hasHistory = true
    }
}
