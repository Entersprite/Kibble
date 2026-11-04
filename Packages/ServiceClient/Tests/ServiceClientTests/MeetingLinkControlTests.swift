import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingLinkControlTests {
    @Test func explicitLinksUseTheExistingOwnerLeaseAndDoNotFabricateAConversation() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let initial = try await harness.read(account)
        #expect(initial.supportsMeetingLinks == true)
        let id = UUID(), sourceID = try #require(initial.sourceID)
        let join = try JoinMeetingCall(
            url: #require(URL(string: "https://meet.example.test/room")),
            callID: id,
            sourceID: sourceID
        )
        _ = try await harness.client().call(join, account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).meetingCall?.phase == .connected }
        let current = try await harness.read(account)
        #expect(current.call == nil)
        #expect(current.conversationCall == nil)
        #expect(current.meetingCall?.target.conversationID == nil)
        #expect(current.meetingCall?.target.meetingURL == join.url)
        try await verifyOwner(harness, account: account, callID: id, sourceID: sourceID)
        _ = try await harness.client().call(
            ControlCallInteraction(callID: id, sourceID: sourceID, raised: true),
            account: account.id,
            revision: account.currentRevision
        )
        try await callEventually {
            try await harness.read(account).participants?.first(where: \.isLocal)?.handRaised == true
        }
        let invite = InviteCallParticipant(callID: id, sourceID: sourceID, memberID: .init("peer"))
        _ = try await harness.client().call(invite, account: account.id, revision: account.currentRevision)
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(invite, account: account.id, revision: account.currentRevision)
        }
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        #expect(source.invitedMembers == [.init("peer")])
        let other = harness.accounts[1], otherState = try await harness.read(other)
        await #expect(throws: ServiceFailure.deviceBusy) {
            try await harness.client().call(
                JoinMeetingCall(url: join.url, callID: UUID(), sourceID: #require(otherState.sourceID)),
                account: other.id,
                revision: other.currentRevision
            )
        }
        _ = try await harness.client().call(
            ControlCall(action: "hangUp", callID: id, sourceID: sourceID),
            account: account.id,
            revision: account.currentRevision
        )
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(join, account: account.id, revision: account.currentRevision)
        }
        await harness.service.shutdown()
    }

    @Test func replacementMeetingMetadataIsDeliveredEvenWhenItsValuesAreEqual() throws {
        let stream = UUID().uuidString
        let target = try ConversationCallTarget(
            meetingURL: #require(URL(string: "https://meet.example.test/room")),
            displayName: "Meeting"
        )
        let first = ConversationCallSnapshot(id: UUID(), target: target, phase: .connected)
        let second = ConversationCallSnapshot(id: UUID(), target: target, phase: .connected)
        let interaction = CallInteractionState(joinURL: target.meetingURL, canRaiseHand: true)
        var projection = ServiceCallStateProjection()
        _ = try projection.accept(ServiceCallState(
            version: stream + ":1",
            meetingCall: first,
            interaction: interaction
        ))
        let replacement = ServiceCallState(
            version: stream + ":2",
            meetingCall: second,
            interaction: interaction
        )
        let events = try projection.accept(replacement)
        #expect(events.contains(.meetingSnapshot(second)))
        #expect(events.contains(.interactionChanged(callID: second.id, state: interaction)))
        guard case let .object(fields) = try ServiceCodec.value(replacement) else {
            Issue.record("Expected a call state object"); return
        }
        #expect(fields["conversationCall"] == nil)
        #expect(fields["meetingCall"] != nil)
    }

    @Test func rejectedLinkFormatIsClassifiedBeforeReservingOrConsumingTheCall() async throws {
        let harness = try await CallHarness.make(), account = harness.accounts[0]
        let source = try #require(try await harness.read(account).sourceID), id = UUID()
        let invalid = try #require(URL(string: "https://meet.example.test/room?secret=value"))
        let failure = ServiceFailure(code: "invalidRequest", details: .object([
            "callStage": .string("meetingLinkNormalization")
        ]))
        await #expect(throws: failure) {
            try await harness.client().call(
                JoinMeetingCall(url: invalid, callID: id, sourceID: source),
                account: account.id,
                revision: account.currentRevision
            )
        }
        #expect(try await harness.read(account).currentCallID == nil)
        let valid = try #require(URL(string: "https://meet.example.test/room"))
        _ = try await harness.client().call(
            JoinMeetingCall(url: valid, callID: id, sourceID: source),
            account: account.id,
            revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).meetingCall?.phase == .connected }
        await harness.service.shutdown()
    }

    @Test func insecureLinkRefusalIdentifiesTheEnvelopeCheckWithoutCallingTheProvider() async throws {
        let harness = try await CallHarness.make(), account = harness.accounts[0]
        let source = try #require(try await harness.read(account).sourceID)
        let url = try #require(URL(string: "http://meet.example.test/room"))
        let failure = ServiceFailure(code: "invalidRequest", details: .object([
            "callStage": .string("meetingLinkEnvelope")
        ]))
        await #expect(throws: failure) {
            try await harness.client().call(
                JoinMeetingCall(url: url, callID: UUID(), sourceID: source),
                account: account.id, revision: account.currentRevision
            )
        }
        #expect(try await harness.read(account).currentCallID == nil)
        await harness.service.shutdown()
    }

    private func verifyOwner(
        _ harness: CallHarness,
        account: AccountRecord,
        callID: UUID,
        sourceID: UUID
    ) async throws {
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.client(session: "intruder").call(
                ControlCallInteraction(callID: callID, sourceID: sourceID, raised: true),
                account: account.id, revision: account.currentRevision
            )
        }
    }

    @Test func staleSourcesCannotJoinLinksOrMutateAnotherCall() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        await #expect(throws: ServiceFailure.staleCallSource) {
            try await harness.client().call(
                JoinMeetingCall(
                    url: #require(URL(string: "https://meet.example.test/room")),
                    callID: UUID(),
                    sourceID: UUID()
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        let state = try await harness.read(account)
        #expect(state.currentCallID == nil)
        await harness.service.shutdown()
    }
}
