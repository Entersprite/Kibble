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

    @Test func presenterMintsSeparateCredentialAndLeavesOnlyItsOwnDeviceWithoutInviting() async throws {
        let primary = "spaces/demo/devices/one", child = "spaces/demo/devices/presenter"
        func childResponse(_ state: UInt64, capture: UInt64 = 1) -> HTTPResponse {
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: base64(MeetProto.string(1, child)
                    + MeetProto.number(4, state) + MeetProto.string(21, primary) + MeetProto.number(
                        25,
                        capture
                    )))
        }
        let transport = FakeHTTPTransport(responses: [
            response(state: 2),
            response(state: 1, token: "30;joined"),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("x-goog-meeting-token", "40;parent-rotation")]),
                body: base64(MeetProto.string(1, "15;secondary-credential"))
            ),
            childResponse(2),
            childResponse(1, capture: 2),
            childResponse(6, capture: 2),
            response(state: 6)
        ])
        let parent = try makeSession(transport)
        await #expect(throws: MeetDeviceSessionError.notJoined) { _ = try await parent.makePresenter() }
        try await parent.register(mediaSession: "mediasessions/native")
        await parent.setMediaConnected(true); try await parent.join()
        let presenter = try await parent.makePresenter()
        try await presenter.register(mediaSession: "mediasessions/presentation")
        await presenter.setMediaConnected(true); try await presenter.join()
        await #expect(throws: MeetDeviceSessionError.notJoined) {
            try await presenter.invite(calleeID: "peer", requestID: UUID())
        }
        try await presenter.leave()
        #expect(await parent.localDeviceName == primary)
        #expect(await presenter.localDeviceName == nil)
        try await parent.leave()
        let requests = await transport.sent
        #expect(requests.count == 7)
        #expect(requests[2].url.path.hasSuffix("CreateTokenForSecondary"))
        #expect(requests[2].body == Data([0x0A, 0x0B] + Array("spaces/demo".utf8)))
        #expect(requests[2].headers["x-goog-meeting-token"] == "30;joined")
        #expect(requests[2].headers["x-goog-ext-174067345-bin"] == nil)
        #expect(requests[3].headers["x-goog-meeting-token"] == "15;secondary-credential")
        #expect(requests[6].headers["x-goog-meeting-token"] == "40;parent-rotation")
        let joined = try MeetProto.payload(1, #require(requests[4].body))
        #expect(try MeetProto.value(25, joined) == 2)
        #expect(try MeetProto.text(1, joined) == child)
        let left = try MeetProto.payload(1, #require(requests[5].body))
        #expect(try MeetProto.text(1, left) == child)
    }

    @Test func presentationClassificationPreservesSameSpaceParentScope() throws {
        let child = MeetProto.string(1, "spaces/demo/devices/presenter") + MeetProto.number(4, 2)
        let linked = try MeetDeviceWire.device(from: base64(child
                + MeetProto.string(21, "spaces/demo/devices/one")), in: "spaces/demo")
        #expect(linked.isPresentation)
        let presentation = try MeetDeviceWire.device(
            from: base64(child + MeetProto.number(25, 2)),
            in: "spaces/demo"
        )
        #expect(presentation.isPresentation)
        #expect(throws: (any Error).self) {
            try MeetDeviceWire.device(from: base64(child
                    + MeetProto.string(21, "spaces/foreign/devices/one")), in: "spaces/demo")
        }
    }

    @Test func presenterCannotRetainOrLeaveAnEchoOfTheParentDevice() async throws {
        let transport = FakeHTTPTransport(responses: [
            response(state: 2),
            response(state: 1),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: base64(MeetProto.string(1, "15;secondary"))
            ),
            response(state: 2)
        ])
        let parent = try makeSession(transport)
        try await parent.register(mediaSession: "mediasessions/native")
        await parent.setMediaConnected(true)
        try await parent.join()
        let child = try await parent.makePresenter()
        await #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try await child.register(mediaSession: "mediasessions/presentation")
        }
        #expect(await child.localDeviceName == nil)
        await #expect(throws: MeetDeviceSessionError.leaveUnconfirmed) { try await child.leave() }
        #expect(await parent.localDeviceName == "spaces/demo/devices/one")
        #expect(await transport.sent.count == 4)
    }

    @Test func secondaryTokenRefusalOrMalformedBodyCannotFallBackToTheParentToken() async throws {
        let responses = [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: base64(MeetProto.string(1, "not-a-token"))
            )
        ]
        for failure in responses {
            let transport = FakeHTTPTransport(responses: [
                response(state: 2),
                response(state: 1),
                failure,
                response(state: 6)
            ])
            let parent = try makeSession(transport)
            try await parent.register(mediaSession: "mediasessions/native")
            await parent.setMediaConnected(true); try await parent.join()
            await #expect(throws: (any Error).self) { _ = try await parent.makePresenter() }
            #expect(await parent.localDeviceName == "spaces/demo/devices/one")
            #expect(await transport.sent.count == 3)
            try await parent.leave()
            #expect(await transport.sent.count == 4)
        }
    }

    @Test func secondaryTokenRequestRequiresASpaceAndRejectsDeviceResources() throws {
        #expect(try MeetDeviceWire.secondaryTokenRequest(space: "spaces/demo")
            == Data([0x0A, 0x0B] + Array("spaces/demo".utf8)))
        for invalid in ["", "spaces/", "spaces/demo/devices/one", "spaces/demo/extra", "spaces/demo?x"] {
            #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
                try MeetDeviceWire.secondaryTokenRequest(space: invalid)
            }
        }
    }

    @Test func secondaryTokenSchemaRejectsUnsafeDuplicateEmptyAndOversizedCredentials() {
        let invalid = [
            MeetProto.string(1, ""),
            MeetProto.string(1, "15;"),
            MeetProto.string(1, "15;bad\n"),
            MeetProto.string(1, "15;first") + MeetProto.string(1, "16;second"),
            MeetProto.string(1, "15;" + String(repeating: "x", count: 16384))
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try MeetDeviceWire.secondaryToken(from: base64(value)) }
        }
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
