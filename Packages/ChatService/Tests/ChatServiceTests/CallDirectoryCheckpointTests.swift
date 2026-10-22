import ChatAPI
import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct CallDirectoryCheckpointTests {
    @Test func committedProviderBatchesUpdateRingingEligibilityWithoutAChatClient() async throws {
        let harness = try await ReconciliationHarness.make(checkpointing: true)
        try await authEventually { await harness.backend.acknowledgedBatches.contains("fixture-connected") }
        let runtime = try #require(await harness.service.runtimes[harness.record.id])
        let source = await FixtureAudioCallService()
        await runtime.installCalls([.init("device"): source])
        do {
            try await authEventually { await MainActor.run { source.recipients.isEmpty } }
            let me = await runtime.record.selfID
            let peer = Member(id: .init("caller"), kind: .human, displayName: "Caller")
            let dm = Conversation(id: .init("dm"), kind: .directMessage, members: [me, peer.id])
            await harness.backend.deliverBatch(.init(
                id: "directory", events: [.membersResolved([peer])],
                directory: .init(conversations: [dm]), previousCheckpoint: nil, checkpoint: nil
            ))
            try await authEventually { await harness.backend.acknowledgedBatches.contains("directory") }
            try await authEventually {
                await MainActor.run { source.recipients.first?.conversationID == dm.id }
            }
            let recipient = try #require(await source.recipients.first)
            #expect(await source.receiveIncoming(from: recipient) != nil)
            await harness.backend.deliverBatch(.init(
                id: "removed", events: [.conversationRemoved(conversationID: dm.id, historyBefore: nil)],
                previousCheckpoint: nil, checkpoint: nil
            ))
            try await authEventually { await harness.backend.acknowledgedBatches.contains("removed") }
            try await authEventually { await MainActor.run { source.recipients.isEmpty } }
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }
}
