import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ExistingCallControlTests {
    @Test func joinIsSerializedOwnedAndCannotReplayOrTakeAnotherAccountsMedia() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let other = harness.accounts[1]
        let initial = try await harness.read(account)
        #expect(initial.supportsExistingJoin == true)
        let recipient = try #require(initial.recipients.first)
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        source.setExistingCallAvailable(true, in: recipient.conversationID)
        let id = UUID()
        let request = ControlCall(
            action: "join",
            callID: id,
            recipient: recipient,
            sourceID: initial.sourceID
        )
        _ = try await harness.client().call(request, account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).call?.phase == .connected }
        #expect(source.currentCall?.id == id)
        await #expect(throws: ServiceFailure.invalidRequest) {
            try await harness.client().call(request, account: account.id, revision: account.currentRevision)
        }
        let otherState = try await harness.read(other)
        let otherRecipient = try #require(otherState.recipients.first)
        await #expect(throws: ServiceFailure.deviceBusy) {
            try await harness.client().call(
                ControlCall(
                    action: "join",
                    callID: UUID(),
                    recipient: otherRecipient,
                    sourceID: otherState.sourceID
                ),
                account: other.id, revision: other.currentRevision
            )
        }
        _ = try await harness.client().call(
            ControlCall(action: "hangUp", callID: id, sourceID: initial.sourceID),
            account: account.id, revision: account.currentRevision
        )
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(request, account: account.id, revision: account.currentRevision)
        }
        await harness.service.shutdown()
    }

    @Test func anUnavailableExistingCallFailsAndReleasesTheDeviceWithoutStartingANewCall() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let initial = try await harness.read(account)
        let recipient = try #require(initial.recipients.first)
        let id = UUID()
        await #expect(throws: (any Error).self) {
            try await harness.client().call(
                ControlCall(action: "join", callID: id, recipient: recipient, sourceID: initial.sourceID),
                account: account.id, revision: account.currentRevision
            )
        }
        try await callEventually { try await harness.read(account).call?.phase == .failed }
        let other = harness.accounts[1]
        let state = try await harness.read(other)
        let otherRecipient = try #require(state.recipients.first)
        _ = try await harness.client().call(
            ControlCall(action: "start", callID: UUID(), recipient: otherRecipient, sourceID: state.sourceID),
            account: other.id, revision: other.currentRevision
        )
        try await callEventually { try await harness.read(other).call?.phase == .connected }
        await harness.service.shutdown()
    }
}
