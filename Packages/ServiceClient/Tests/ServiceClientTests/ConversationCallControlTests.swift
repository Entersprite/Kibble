import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConversationCallControlTests {
    @Test func groupControlsShareDMOwnershipAndDeviceReservationsAndCannotReplay() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let initial = try await harness.read(account)
        #expect(initial.supportsConversationCalls == true)
        let id = UUID()
        let request = try ControlConversationCall(
            action: "start", conversationID: .init("group"), callID: id,
            sourceID: #require(initial.sourceID)
        )
        _ = try await harness.client().call(request, account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).conversationCall?.phase == .connected }
        let state = try await harness.read(account)
        #expect(state.call == nil)
        #expect(state.conversationCall?.target.displayName == "Test group")
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        let person = CallParticipantDevice(id: UUID(), displayName: "Participant")
        source.setParticipantDevices([person], callID: id)
        try await callEventually { try await harness.read(account).participants == [person] }
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.client(session: "intruder").call(
                ControlCall(action: "hangUp", callID: id, sourceID: initial.sourceID),
                account: account.id, revision: account.currentRevision
            )
        }
        let other = harness.accounts[1]
        let otherState = try await harness.read(other)
        await #expect(throws: ServiceFailure.deviceBusy) {
            try await harness.client().call(
                ControlCall(
                    action: "start",
                    callID: UUID(),
                    recipient: otherState.recipients.first,
                    sourceID: otherState.sourceID
                ),
                account: other.id, revision: other.currentRevision
            )
        }
        _ = try await harness.client().call(
            ControlCall(action: "mute", callID: id, muted: true, sourceID: initial.sourceID),
            account: account.id, revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).conversationCall?.isMuted == true }
        _ = try await harness.client().call(
            ControlCall(action: "hangUp", callID: id, sourceID: initial.sourceID),
            account: account.id, revision: account.currentRevision
        )
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(request, account: account.id, revision: account.currentRevision)
        }
        await harness.service.shutdown()
    }

    @Test func aMembershipInvalidationWhilePreflightIsHeldCannotStartMedia() async throws {
        let harness = try await CallHarness.make(heldMembership: true)
        let account = harness.accounts[0]
        let state = try await harness.read(account)
        let gate = try #require(await harness.providers.gate(account.id))
        let runtime = try #require(await harness.service.runtimes[account.id])
        let request = try ControlConversationCall(
            action: "start", conversationID: .init("group"), callID: UUID(),
            sourceID: #require(state.sourceID)
        )
        let control = Task { try await harness.client().call(
            request,
            account: account.id,
            revision: account.currentRevision
        ) }
        try await callEventually { await gate.held }
        await runtime.invalidateCallFacts(for: .conversationClassified(.init(
            id: .init("group"),
            kind: .appDirectMessage
        )))
        await gate.release()
        await #expect(throws: ServiceFailure.overloaded) { try await control.value }
        #expect(try await harness.read(account).conversationCall == nil)
        await harness.service.shutdown()
    }

    @Test func missingGroupCallCannotJoinOrReserveTheDeviceAndDMTargetsAreRefused() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let initial = try await harness.read(account)
        for conversation in ["group", "same", "unjoined"] {
            await #expect(throws: (any Error).self) {
                try await harness.client().call(
                    ControlConversationCall(
                        action: "join", conversationID: .init(conversation), callID: UUID(),
                        sourceID: #require(initial.sourceID)
                    ), account: account.id, revision: account.currentRevision
                )
            }
        }
        let other = harness.accounts[1]
        let state = try await harness.read(other)
        _ = try await harness.client().call(
            ControlCall(
                action: "start",
                callID: UUID(),
                recipient: state.recipients.first,
                sourceID: state.sourceID
            ),
            account: other.id, revision: other.currentRevision
        )
        try await callEventually { try await harness.read(other).call?.phase == .connected }
        await harness.service.shutdown()
    }
}
