import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallSourceFenceTests {
    @Test func anOldSerializedInvitationCannotRingAfterDisableAndReenable() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let client = harness.client()
        let original = try await harness.read(account)
        let recipient = try #require(original.recipients.first)
        let request = ControlCall(
            action: "start",
            callID: UUID(),
            recipient: recipient,
            sourceID: original.sourceID
        )
        _ = try await client.call(request, account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).call?.phase == .connected }
        _ = try await client.setEnabled(false, account: account.id)
        _ = try await client.setEnabled(true, account: account.id)
        try await callEventually {
            guard let current = try? await harness.read(account) else { return false }
            return current.isListening && current.sourceID != original.sourceID
        }
        await #expect(throws: ServiceFailure.staleCallSource) {
            try await client.call(request, account: account.id, revision: account.currentRevision)
        }
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        #expect(source.currentCall == nil)
        #expect(try await harness.read(account).call == nil)
        await harness.service.shutdown()
    }
}
