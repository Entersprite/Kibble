import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MeetingLinkControlTests {
    @Test func previewTitleUsesTheCurrentAccountAndLeavesCallStateAlone() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0], other = harness.accounts[1]
        let initial = try await harness.read(account)
        #expect(initial.supportsMeetingLinkPreview == true)
        let client = harness.client()
        let summary = try #require(try await client.accounts().first { $0.id == account.id })
        let facade = try ServiceAudioCallService(account: summary, client: client)
        try await facade.startListening()
        #expect(facade.canPreviewMeetingLinks)
        let url = try #require(URL(string: "https://meet.example.test/room"))
        #expect(try await facade.previewMeetingTitle(at: url) == "Fixture Meeting")
        #expect(try await facade.previewMeetingTitle(
            at: url, reference: Date(timeIntervalSince1970: 1_800_000_000), calendarOnly: true
        ) == "Fixture Meeting")
        let unknown = try #require(URL(string: "https://other.example.test/room"))
        #expect(try await facade.previewMeetingTitle(at: unknown) == nil)
        let request = try PreviewMeetingLink(url: url, sourceID: #require(initial.sourceID))
        await #expect(throws: ServiceFailure.staleCallSource) {
            try await harness.client().call(request, account: other.id, revision: other.currentRevision)
        }
        #expect(try await harness.read(account).currentCallID == nil)
        #expect(try await harness.read(other).currentCallID == nil)
        await facade.stop()
        await harness.service.shutdown()
    }

    @Test func serializedFacadeCarriesInitialMuteThroughAdmission() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0], client = harness.client()
        let summary = try #require(try await client.accounts().first { $0.id == account.id })
        let facade = try ServiceAudioCallService(account: summary, client: client)
        try await facade.startListening()
        #expect(facade.canConfigureMeetingJoinMedia)
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        fixture.nextMeetingAdmission = .waitingRoom
        let url = try #require(URL(string: "https://meet.example.test/room"))
        let id = UUID()
        try await facade.joinMeeting(at: url, callID: id, media: .init(microphoneMuted: true))
        try await callEventually {
            let call = try await harness.read(account).meetingCall
            return call?.admission == .waitingRoom && call?.isMuted == true
        }
        fixture.admitMeetingJoin(callID: id)
        try await callEventually {
            let call = try await harness.read(account).meetingCall
            return call?.phase == .connected && call?.isMuted == true
        }
        try await facade.hangUp(callID: id)
        await facade.stop()
        await harness.service.shutdown()
    }

    @Test(arguments: [true, false])
    func pendingAdmissionRemainsWithTheCallOwnerAcrossSerialization(_ admit: Bool) async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let sourceID = try #require(try await harness.read(account).sourceID)
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        fixture.nextMeetingAdmission = .waitingRoom
        let id = UUID()
        let join = try JoinMeetingCall(
            url: #require(URL(string: "https://meet.example.test/room")), callID: id, sourceID: sourceID
        )
        _ = try await harness.client().call(join, account: account.id, revision: account.currentRevision)
        try await callEventually {
            let snapshot = try await harness.read(account)
            return snapshot.meetingCall?.phase == .connecting && snapshot.meetingCall?
                .admission == .waitingRoom
        }
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.client().call(
                ControlCallInteraction(callID: id, sourceID: sourceID, raised: true),
                account: account.id, revision: account.currentRevision
            )
        }
        let hangUp = ControlCall(action: "hangUp", callID: id, sourceID: sourceID)
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.client(session: "other").call(
                hangUp,
                account: account.id,
                revision: account.currentRevision
            )
        }
        if admit {
            fixture.admitMeetingJoin(callID: id)
            try await callEventually {
                let snapshot = try await harness.read(account)
                return snapshot.meetingCall?.phase == .connected && snapshot.meetingCall?.admission == nil
            }
        }
        let ended = try await harness.client().call(
            hangUp,
            account: account.id,
            revision: account.currentRevision
        )
        #expect(ended.meetingCall?.phase == .ended && ended.meetingCall?.admission == nil)
        fixture.admitMeetingJoin(callID: id)
        #expect(try await harness.read(account).meetingCall?.phase == .ended)
        await harness.service.shutdown()
    }

    @Test func createLinkUsesTheAccountSourceOnceAndLeavesCallStateAlone() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0], other = harness.accounts[1]
        let initial = try await harness.read(account)
        #expect(initial.supportsMeetingLinkCreation == true)
        let request = try CreateMeetingLink(requestID: UUID(), sourceID: #require(initial.sourceID))
        let client = harness.client()

        await #expect(throws: ServiceFailure.staleCallSource) {
            try await client.call(request, account: other.id, revision: other.currentRevision)
        }
        let url = try await client.call(request, account: account.id, revision: account.currentRevision)
        #expect(url.host == "meet.example.test")
        await #expect(throws: ServiceFailure.operationConflict) {
            try await client.call(request, account: account.id, revision: account.currentRevision)
        }
        #expect(try await harness.read(account).currentCallID == nil)
        #expect(try await harness.read(other).currentCallID == nil)
        await harness.service.shutdown()
    }

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
        var interaction = CallInteractionState(joinURL: target.meetingURL, canRaiseHand: true)
        interaction.dialIn = CallDialIn(phoneNumber: "+1 202-555-0142", pin: "012345678")
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

    @Test func dialInSurvivesCallStateCodingAndIsOptionalForOlderPeers() throws {
        let old = Data(#"{"joinURL":"https://meet.example.test/room","canRaiseHand":true}"#.utf8)
        var interaction = try JSONDecoder().decode(CallInteractionState.self, from: old)
        #expect(interaction.dialIn == nil)
        #expect(interaction.alternateDialIns == nil)
        #expect(interaction.dialInNumbersURL == nil)
        #expect(interaction.canRaiseHand)
        let minimal = try JSONEncoder().encode(interaction)
        #expect(!String(decoding: minimal, as: UTF8.self).contains("dialIn"))

        interaction.dialIn = CallDialIn(phoneNumber: "+1 202-555-0142", pin: "012345678")
        interaction.alternateDialIns = [CallDialIn(
            phoneNumber: "+44 20 7946 0958",
            pin: "987654321",
            regionCode: "GB"
        )]
        interaction.dialInNumbersURL = try #require(URL(string: "https://tel.meet/abc-defg-hij?hs=5"))
        let state = ServiceCallState(version: "synthetic:1", interaction: interaction)
        let decoded = try JSONDecoder().decode(ServiceCallState.self, from: JSONEncoder().encode(state))
        #expect(decoded.interaction == interaction)
    }

    @Test func discoveringCreationCapabilityNotifiesTheCallControllerWithoutChangingListenerStatus() throws {
        let source = UUID().uuidString
        var projection = ServiceCallStateProjection()
        var state = ServiceCallState(version: source + ":1", isListenerStarting: true)
        _ = try projection.accept(state)
        state.version = source + ":2"
        state.supportsMeetingLinkCreation = true
        #expect(try projection.accept(state) == [.capabilitiesChanged])
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
