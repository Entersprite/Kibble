import Foundation
import Testing
@testable import GChatBridgeCore

extension MeetDeviceSessionTests {
    @Test(arguments: [true, false], [UInt64(5), UInt64(7)])
    func settledParticipantInvitesDoNotCancelOthers(observedEarly: Bool, status: UInt64) async throws {
        let ringing = invitationSnapshot(4, states: [("answered-invite", 3), ("pending-invite", 3)])
        let settled = invitationSnapshot(5, states: [("answered-invite", status), ("pending-invite", 3)])
        let collect = observedEarly ? [settled, ringing] : [ringing, settled]
        let transport = FakeHTTPTransport(responses: [
            response(state: 2), response(state: 1), inviteReceipt("answered-invite"),
            inviteReceipt("pending-invite")
        ] + collect + [inviteReceipt("pending-invite"), response(state: 6)])
        let session = try makeSession(transport)
        try await session.register(mediaSession: "mediasessions/native")
        await session.setMediaConnected(true)
        try await session.join()
        try await session.inviteParticipant(calleeID: "guest1")
        try await session.inviteParticipant(calleeID: "guest2")
        _ = try await session.collections()
        try await session.cancelParticipantInvitations()
        try await session.leave()

        let requests = await transport.sent
        let cancellations = requests.filter { $0.url.lastPathComponent == "CancelMeetingInvite" }
        #expect(cancellations.count == 1)
        let cancelled = try #require(cancellations.first?.body)
        #expect(try MeetProto.text(1, cancelled) == "pending-invite")
        #expect(requests.last?.url.lastPathComponent == "UpdateMeetingDevice")
        let finalRead = try #require(requests.dropLast(2).last?.body)
        #expect(ProtoFieldScan.fields(in: finalRead).fields.map(\.number) == [1, 12])
    }

    private func inviteReceipt(_ id: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: base64(MeetProto.string(1, id)))
    }

    private func invitationSnapshot(_ version: UInt64, states: [(String, UInt64)]) -> HTTPResponse {
        let metadata = MeetProto.bytes(1, MeetProto.number(1, version))
        let full = states.reduce(into: metadata) { data, state in
            data += MeetProto.bytes(2, MeetProto.string(1, state.0) + MeetProto.number(6, state.1))
        }
        return HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: base64(MeetProto.bytes(11, MeetProto.bytes(2, full)))
        )
    }
}
