import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

private enum ExistingCallFixture {
    static func group(
        reference: String = "existing-secret", status: Int32 = 1, conference: String = "first-conference"
    )
        throws -> Result<HTTPResponse, any Error> {
        var response = GetGroupResponse()
        response.group.groupID.dmID.dmID = "valid-dm"
        response.membershipState = .memberJoined
        var payload = SpaceIntegrationPayload()
        payload.type = 5
        payload.callIntegrationPayload.callStatus = status
        payload.callIntegrationPayload.callMetadata.meetMetadata.meetingType = 1
        payload.callIntegrationPayload.callMetadata.meetMetadata.meetingCode = reference
        payload.callIntegrationPayload.callMetadata.meetMetadata.conferenceName = conference
        response.group.spaceIntegrationPayloads = [payload]
        return try .success(HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: response.serializedData()
        ))
    }

    static func preparation(
        finalReference: String = "existing-secret", finalConference: String = "first-conference"
    ) throws -> [Result<
        HTTPResponse,
        any Error
    >] {
        let fixtures = MeetDMCallTrialTests()
        var resolved = try NativeMeetFixture.responses()[0].get()
        resolved.headers = HTTPHeaders(fields: resolved.headers.fields + [.init(
            name: "X-Goog-Meeting-Debugid", value: "conference-sentinel"
        )])
        return try [
            fixtures.loadingResponses()[0],
            group(),
            fixtures.preparingResponses()[0],
            .success(resolved)
        ]
            + [group(reference: finalReference, conference: finalConference)]
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ExistingCallJoinTests {
    @Test func preparationResolvesTheCurrentReferenceAndCannotRing() async throws {
        let fixtures = MeetDMCallTrialTests()
        let transport = try ScriptedTransport(fixtures.loadingResponses() + ExistingCallFixture.preparation())
        let (trial, _) = try await fixtures.trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        let prepared = try await trial.prepareExisting(person: person.id)
        #expect(await trial.prepared?.permitsInvitation == false)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: prepared.id)
        }
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.prepareRingAfterBrowserJoin(preparedID: prepared.id)
        }
        let requests = await transport.sent
        let resolution = try #require(requests.first { $0.url.path.hasSuffix("ResolveMeetingSpace") })
        #expect(resolution.body == NativeMeetFixture.string(1, "existing-secret"))
        #expect(requests.allSatisfy { !$0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(requests.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(await trial.report.contains("existing-secret") == false)
        await trial.close()
    }

    @Test(arguments: [false, true])
    func replacementDuringResolutionCannotPrepareMedia(reusesCode: Bool) async throws {
        let fixtures = MeetDMCallTrialTests()
        let transport = try ScriptedTransport(
            fixtures.loadingResponses() + ExistingCallFixture.preparation(
                finalReference: reusesCode ? "existing-secret" : "replacement",
                finalConference: "second-conference"
            )
        )
        let (trial, _) = try await fixtures.trial(transport)
        let person = try #require(try await trial.loadPeople().first)
        await #expect(throws: MeetDMCallTrialError.callChanged) {
            try await trial.prepareExisting(person: person.id)
        }
        #expect(await trial.prepared == nil)
        #expect(await trial.native == nil)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingDevice") })
        await trial.close()
    }

    @Test @MainActor func explicitJoinConnectsNativeMediaWithoutAnInvitation() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let responses = try ExistingCallFixture.preparation() + fixtures.nativeResponses().dropFirst(2)
        let setup = try await fixtures.setup(Array(responses))
        try await setup.service.startListening()
        let recipient = try fixtures.recipient(setup)
        let joining: any ExistingAudioCallService = setup.service
        let id = UUID()
        try await joining.joinExisting(to: recipient, callID: id)
        #expect(setup.service.snapshot?.id == id)
        #expect(setup.service.snapshot?.phase == .connecting)
        #expect(setup.media.engines.count == 1)
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
        #expect(await setup.base.sent.allSatisfy { !$0.url.path.hasSuffix("ResolveForHangoutsChat") })
        try await setup.service.hangUp(callID: id)
        #expect(setup.media.engines[0].closed)
        #expect(setup.service.snapshot?.phase == .ended)
        await setup.service.stop()
    }
}
