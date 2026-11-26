import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct TypingInterestTests {
    @Test func oneClientStoppingDoesNotWithdrawAnotherClientsTypingAndExpiryEventuallyDoes() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        try await allowTyping(harness, true)
        let firstClient = InterestTestClient(harness, device: "device", session: "client")
        let secondClient = InterestTestClient(harness, device: "other", session: "client")
        let first = try await firstClient.attach(), second = try await secondClient.attach()
        let start = ChatCommand.setTyping(
            conversationID: ReconciliationBackend.conversation,
            threadID: nil,
            isTyping: true
        )
        let stop = ChatCommand.setTyping(
            conversationID: ReconciliationBackend.conversation,
            threadID: nil,
            isTyping: false
        )
        try await firstClient.hint(start, lease: first)
        try await secondClient.hint(start, lease: second)
        try await authEventually { await harness.backend.sentCommands.contains(start) }
        try await firstClient.hint(stop, lease: first)
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let revision = await runtime.interestRevision
        try await runtime.awaitInterestPublication(revision)
        #expect(await !harness.backend.sentCommands.contains(stop))
        await runtime.expireClientInterests(at: .now + .seconds(7))
        try await authEventually { await harness.backend.sentCommands.last == stop }
        #expect(await runtime.clientInterests.values.count(where: { $0.lease != nil }) == 2)
        await harness.service.shutdown()
    }

    @Test func policyRevocationWaitsForALateTypingStartThenWithdrawsItBeforeAcknowledging() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        try await allowTyping(harness, true)
        await harness.backend.holdNextTyping()
        let start = ChatCommand.setTyping(
            conversationID: ReconciliationBackend.conversation,
            threadID: nil,
            isTyping: true
        )
        try await harness.hint(start)
        try await authEventually { await harness.backend.typingHeld }
        let revoking = Task { try await allowTyping(harness, false) }
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        do {
            try await authEventually { await runtime.interestWaiters.count == 1 }
        } catch {
            await harness.backend.releaseTyping()
            _ = await revoking.result
            await harness.service.shutdown()
            throw error
        }
        #expect(try harness.registry.policy(for: harness.record).settings.resolvedGlobal
            .sharesTyping == false)
        await harness.backend.releaseTyping()
        try await revoking.value
        let stop = ChatCommand.setTyping(
            conversationID: ReconciliationBackend.conversation,
            threadID: nil,
            isTyping: false
        )
        #expect(await harness.backend.sentCommands == [start, stop])
        await harness.service.shutdown()
    }

    @Test func disableDrainsAHeldInterestPublisherBeforeReleasingRuntimeResources() async throws {
        let harness = try await ReconciliationHarness.make()
        _ = try await harness.call(LoadConversations())
        try await allowTyping(harness, true)
        await harness.backend.holdNextTyping()
        try await harness.hint(.setTyping(
            conversationID: ReconciliationBackend.conversation,
            threadID: nil,
            isTyping: true
        ))
        try await authEventually { await harness.backend.typingHeld }
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let disabling = Task { try await harness.call(SetAccountEnabled(enabled: false)) }
        try await authEventually {
            let stopped = await runtime.stopped
            let disconnects = await harness.backend.disconnects
            return stopped && disconnects > 0
        }
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.backend.releaseTyping()
        _ = try await disabling.value
        #expect(await harness.service.activeRuntimeCount == 0)
        #expect(await runtime.clientInterests.isEmpty)
        #expect(await runtime.interestPublisher == nil)
        #expect(await runtime.interestSweep == nil)
        await harness.service.shutdown()
    }

    private func allowTyping(_ harness: ReconciliationHarness, _ allowed: Bool) async throws {
        let before = try await harness.call(GetAccountPolicy())
        var settings = before.settings
        settings.setRule(
            NotificationRule(sharesTyping: allowed),
            for: .global,
            at: ReconciliationBackend.date,
            by: "device"
        )
        _ = try await harness.call(SetAccountPolicy(settings: settings, expectedRevision: before.revision))
    }
}
