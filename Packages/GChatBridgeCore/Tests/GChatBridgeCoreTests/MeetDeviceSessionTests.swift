import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetDeviceSessionTests {
    @Test func ringRequiresConnectedMediaAndAcceptedJoinAndUsesNewestToken() async throws {
        let transport = FakeHTTPTransport(responses: [
            response(state: 2, token: "20;registered"),
            response(state: 1, token: "30;joined"),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: base64(MeetProto.string(1, "invite"))),
            response(state: 6, token: "40;left")
        ])
        let session = try makeSession(transport)
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(calleeID: "peer", requestID: UUID())
        }
        try await session.register(mediaSession: "mediasessions/native")
        await #expect(throws: MeetDeviceSessionError.mediaNotConnected) { try await session.join() }
        await session.setMediaConnected(true)
        try await session.join()
        try await session.invite(calleeID: "peer", requestID: UUID())
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(calleeID: "peer", requestID: UUID())
        }
        try await session.leave()
        let sent = await transport.sent
        #expect(sent.count == 4)
        #expect(sent.map { $0.headers["x-goog-meeting-token"] } == [
            "10;resolved", "20;registered", "30;joined", "30;joined"
        ])
        #expect(sent[0].headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(sent[2].headers["x-goog-ext-174067345-bin"] == nil)
        let create = try MeetProto.payload(2, #require(sent[0].body))
        #expect(try MeetProto.text(22, create) == "native")
        let leave = try MeetProto.payload(1, #require(sent[3].body))
        #expect(try MeetProto.value(4, leave) == 6)
        await #expect(throws: MeetDeviceSessionError.closed) { try await session.join() }
        try await session.leave()
        #expect(await transport.sent.count == 4)
    }

    @Test func lobbyOrMediaLossCannotRing() async throws {
        let transport = FakeHTTPTransport(responses: [response(state: 2), response(state: 3)])
        let session = try makeSession(transport)
        try await session.register(mediaSession: "mediasessions/native")
        await session.setMediaConnected(true)
        await #expect(throws: MeetDeviceSessionError.notJoined) { try await session.join() }
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(calleeID: "peer", requestID: UUID())
        }
        await session.setMediaConnected(false)
        await #expect(throws: MeetDeviceSessionError.mediaNotConnected) { try await session.join() }
        #expect(await transport.sent.count == 2)
    }

    @Test func failedLeaveIsNotReportedAsSuccessAndCanBeExplicitlyRetried() async throws {
        let transport = FakeHTTPTransport(responses: [
            response(state: 2), response(state: 1), response(state: 6)
        ])
        let session = try makeSession(transport)
        try await session.register(mediaSession: "mediasessions/native")
        await #expect(throws: MeetDeviceSessionError.leaveUnconfirmed) { try await session.leave() }
        await #expect(throws: MeetDeviceSessionError.closed) { try await session.join() }
        #expect(await transport.sent.count == 2)
        try await session.leave()
        #expect(await transport.sent.count == 3)
    }

    @Test func responseFromAnotherSpaceOrDeviceIsRejected() throws {
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetDeviceWire.device(from: response(state: 1).body, in: "spaces/another")
        }
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetDeviceWire.create(space: "spaces/demo/extra", mediaSession: "mediasessions/native")
        }
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetDeviceWire.leave(device: "spaces/demo/devices/one?extra")
        }
    }

    @Test func timestampsRejectStaleMalformedOrEqualTokenRotations() {
        var token = MeetMeetingToken()
        token.absorb("20;newest")
        for value in ["10;older", "20;equal", "invalid", "21;", "21;unsafe\n"] {
            token.absorb(value)
            #expect(token.value == "20;newest")
        }
        token.absorb("30;next")
        #expect(token.value == "30;next")
    }

    @Test func ambiguousInviteIsConsumedAndErrorTokenIsRetainedForLeave() async throws {
        let failure = HTTPResponse(
            status: 500, headers: HTTPHeaders([("x-goog-meeting-token", "40;error-rotation")]),
            body: base64(MeetProto.number(1, 13))
        )
        let transport = FakeHTTPTransport(responses: [
            response(state: 2, token: "20;registered"), response(state: 1, token: "30;joined"),
            failure, response(state: 6)
        ])
        let session = try makeSession(transport)
        try await session.register(mediaSession: "mediasessions/native")
        await session.setMediaConnected(true)
        try await session.join()
        await #expect(throws: MeetCallClientError.httpStatus(
            500,
            refusal: MeetCallRefusal(body: failure.body)
        )) {
            try await session.invite(calleeID: "peer", requestID: UUID())
        }
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await session.invite(calleeID: "peer", requestID: UUID())
        }
        try await session.leave()
        let sent = await transport.sent
        #expect(sent.count == 4)
        #expect(sent[3].headers["x-goog-meeting-token"] == "40;error-rotation")
    }

    @Test func ambiguousRegistrationCannotRetryOrClaimSuccessfulCleanupWithoutADeviceHandle() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: base64(Data([0x0A, 0x10])))
        ])
        let session = try makeSession(transport)
        await #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try await session.register(mediaSession: "mediasessions/native")
        }
        await #expect(throws: MeetDeviceSessionError.deviceExists) {
            try await session.register(mediaSession: "mediasessions/native")
        }
        await #expect(throws: MeetDeviceSessionError.leaveUnconfirmed) { try await session.leave() }
        #expect(await transport.sent.count == 1)
    }

    private func makeSession(_ transport: FakeHTTPTransport) throws -> MeetDeviceSession {
        let configuration = try #require(MeetCallConfiguration(
            apiKey: "public", accountIndex: 0, referer: URL(string: "https://meet.google.com/call")!,
            userAgent: "Test", rtcClientID: "CAEQABgB",
            debugID: "test"
        ))
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "synthetic", domain: ".google.com", path: "/")
        ]))
        let client = MeetCallClient(
            transport: transport, credentials: SessionCredentials(cookies),
            configuration: configuration, sha1: { _ in "synthetic" }
        )
        let call = MeetResolvedCall(
            space: .init(
                name: "spaces/demo",
                code: "abc-defg-hij",
                url: URL(string: "https://meet.google.com/abc-defg-hij")!
            ),
            token: "10;resolved"
        )
        return MeetDeviceSession(client: client, call: call)
    }

    private func response(state: UInt64, token: String? = nil) -> HTTPResponse {
        HTTPResponse(
            status: 200, headers: HTTPHeaders(token.map { [("x-goog-meeting-token", $0)] } ?? []),
            body: base64(MeetProto.string(1, "spaces/demo/devices/one") + MeetProto.number(4, state))
        )
    }

    private func base64(_ data: Data) -> Data {
        Data(data.base64EncodedString().utf8)
    }
}
