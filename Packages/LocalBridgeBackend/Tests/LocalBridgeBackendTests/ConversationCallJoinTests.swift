import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ConversationCallJoinTests {
    @Test(arguments: [false, true])
    func quietStartUsesTheConversationAndCannotEnterAnInvitationPath(space: Bool) async throws {
        let fixtures = MeetDMCallTrialTests()
        let response = try group(space: space)
        let transport = try ScriptedTransport(fixtures.loadingResponses() + [
            fixtures.loadingResponses()[0], response, fixtures.preparingResponses()[0],
            NativeMeetFixture.responses()[0], response
        ])
        let (trial, _) = try await fixtures.trial(transport)
        _ = try await trial.loadPeople()
        let id = Conversation.ID(space ? "space/test-group" : "dm/test-group")
        let prepared = try await trial.prepareConversation(in: id, joining: false)
        #expect(await trial.prepared?.target == nil)
        #expect(await trial.prepared?.isConversationCall == true)
        #expect(await trial.prepared?.permitsInvitation == false)
        await #expect(throws: MeetDMCallTrialError.callNotPrepared) {
            try await trial.ring(preparedID: prepared.id)
        }
        let requests = await transport.sent
        let resolve = try #require(requests.first { $0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(try resolve.body == (MeetCallWire.resolveConversation(groupID: "test-group")))
        #expect(!requests.contains { $0.url.path.contains("MeetingInvite") })
        await trial.close()
    }

    @Test(arguments: [false, true])
    func joiningEndedOrMissingHuddlesCannotCreateAReplacement(active: Bool) async throws {
        let fixtures = MeetDMCallTrialTests()
        let transport = try ScriptedTransport(fixtures.loadingResponses() + [
            fixtures.loadingResponses()[0], group(space: true, status: active ? 1 : 3),
            fixtures.preparingResponses()[0], NativeMeetFixture.responses()[0],
            group(space: true, status: 3)
        ])
        let (trial, _) = try await fixtures.trial(transport)
        _ = try await trial.loadPeople()
        await #expect(throws: MeetDMCallTrialError.callChanged) {
            try await trial.prepareConversation(in: .init("space/test-group"), joining: true)
        }
        #expect(await trial.prepared == nil)
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("ResolveForHangoutsChat") })
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingDevice") })
        await trial.close()
    }

    @Test func anUnjoinedOrUnsupportedConversationCannotAllocateNativeMedia() async throws {
        for joined in [false, true] {
            let fixtures = MeetDMCallTrialTests()
            let transport = try ScriptedTransport(fixtures.loadingResponses() + [
                fixtures.loadingResponses()[0], group(space: true, joined: joined, supported: !joined)
            ])
            let (trial, _) = try await fixtures.trial(transport)
            _ = try await trial.loadPeople()
            await #expect(throws: MeetDMCallTrialError.callChanged) {
                try await trial.prepareConversation(in: .init("space/test-group"), joining: false)
            }
            #expect(await transport.sent.allSatisfy { !$0.url.host!.contains("meet.google.com") })
            await trial.close()
        }
    }

    private func group(
        space: Bool, status: Int32? = nil, joined: Bool = true, supported: Bool = true
    ) throws -> Result<HTTPResponse, any Error> {
        var response = GetGroupResponse()
        if space {
            response.group.groupID.spaceID.spaceID = "test-group"
        } else {
            response.group.groupID.dmID.dmID = "test-group"
        }
        response.group.attributeCheckerGroupType = supported
            ? (space ? .flatRoom : .immutableMembershipGroupDm) : .meetingChat
        response.membershipState = joined ? .memberJoined : .memberInvited
        if let status {
            var payload = SpaceIntegrationPayload()
            payload.type = 5
            payload.callIntegrationPayload.callStatus = status
            payload.callIntegrationPayload.callMetadata.meetMetadata.meetingType = 1
            payload.callIntegrationPayload.callMetadata.meetMetadata.meetingCode = "abc-defg-hij"
            response.group.spaceIntegrationPayloads = [payload]
        }
        return try .success(HTTPResponse(
            status: 200,
            headers: HTTPHeaders([]),
            body: response.serializedData()
        ))
    }
}
