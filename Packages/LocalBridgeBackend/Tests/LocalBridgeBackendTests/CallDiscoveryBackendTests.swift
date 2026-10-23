import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf
import Testing
@testable import LocalBridgeBackend

private actor CallDiscoveryTransport: HTTPTransport {
    let base = ActionTransport(kind: .space)
    let transition: Int
    let hold: IgnoringHold?
    let membership: MembershipState
    private(set) var groupReads = 0
    private(set) var rosterReads = 0

    init(transition: Int = 0, hold: IgnoringHold? = nil, membership: MembershipState = .memberJoined) {
        self.transition = transition; self.hold = hold; self.membership = membership
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.lastPathComponent == "get_group" {
            groupReads += 1
            let input = try GetGroupRequest(serializedBytes: request.body ?? Data())
            var response = GetGroupResponse()
            response.group.groupID = input.groupID; response.membershipState = membership
            var envelope = SpaceIntegrationPayload()
            envelope.type = 5
            var call = CallSpaceIntegrationPayload()
            call.callStatus = groupReads > 1 && transition == 3 ? 3 : 1
            call.callMetadata.meetMetadata.meetingType = 1
            call.callMetadata.meetMetadata.meetingCode = groupReads > 1 && transition == 1
                ? "replacement" : "original"
            call.participantListRevisionTimestamp.seconds = 1_700_000_000
            envelope.callIntegrationPayload = call
            response.group.spaceIntegrationPayloads = [envelope]
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: response.serializedData())
        }
        if request.url.lastPathComponent == "batchexecute" {
            rosterReads += 1
            if let hold {
                await hold.wait()
            }
            let data: [Any] = [[[["peer", 1]], 2, NSNull(), [["Guest"]]]]
            return try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: SearchFixtures.answerBody(
                inner: data, rpc: CallDiscoveryRequests.rpc
            ))
        }
        return try await base.send(request)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        try await base.stream(request)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CallDiscoveryBackendTests {
    @Test func readsOnlyCurrentConversationStateAndNeverSendsAnInvitation() async throws {
        let transport = CallDiscoveryTransport()
        let backend = try await connected(transport)
        let calls: any CallDiscoveryBackend = backend
        let value = try await calls.callAvailability(in: .init("space/a"))
        #expect(value.status == .active)
        #expect(value.reference == "original")
        #expect(value.participants?.map(\.memberID?.rawValue) == ["peer", nil])
        #expect(value.participants?.last?.displayName == "Guest")
        #expect(value.totalParticipants == 2)
        #expect(await transport.groupReads == 2)
        #expect(await transport.rosterReads == 1)
        #expect(await transport.base.requests.allSatisfy { !$0.url.absoluteString.contains("Meeting") })
        await backend.disconnect()
    }

    @Test(arguments: [1, 3])
    func aReplacementOrEndDuringTheReadDropsTheOldRoster(_ transition: Int) async throws {
        let transport = CallDiscoveryTransport(transition: transition)
        let backend = try await connected(transport)
        let value = try await backend.callAvailability(in: .init("space/a"))
        #expect(value.status == (transition == 3 ? .inactive : .active))
        #expect(value.participants == nil)
        #expect(value.totalParticipants == nil)
        #expect(value.reference == (transition == 1 ? "replacement" : "original"))
        await backend.disconnect()
    }

    @Test func nonmembersDoNotFetchTheRoster() async throws {
        let transport = CallDiscoveryTransport(membership: .memberInvited)
        let backend = try await connected(transport)
        await #expect(throws: ChatError.self) { try await backend.callAvailability(in: .init("space/a")) }
        #expect(await transport.rosterReads == 0)
        await backend.disconnect()
    }

    @Test func cancellationDoesNotPublishAnAnswerFromAnUncooperativeTransport() async throws {
        let hold = IgnoringHold()
        let transport = CallDiscoveryTransport(hold: hold)
        let backend = try await connected(transport)
        let task = Task { try await backend.callAvailability(in: .init("space/a")) }
        try await SearchBackendSupport.waitUntilEntered(hold)
        task.cancel()
        await hold.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.groupReads == 1)
        await backend.disconnect()
    }

    private func connected(_ transport: CallDiscoveryTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        return backend
    }
}
