import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallClientTests {
    @Test func resolveOnlyGetsASpaceAndInviteUsesItsToken() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("x-goog-meeting-token", "new-token")]),
                body: resolvedBody()
            ),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x0A, 0x01, 0x31]).base64Body)
        ])
        let client = try makeClient(transport: transport)

        let call = try await client.resolve(dmID: "dm_123")
        #expect(call.space.name == "spaces/abc")
        let afterResolve = await transport.sent
        #expect(afterResolve.count == 1)
        #expect(afterResolve[0].url.path.hasSuffix("ResolveForHangoutsChat"))
        #expect(afterResolve[0].headers["x-goog-meeting-token"] == nil)
        #expect(afterResolve[0].headers["Cookie"] == "SID=shared; SAPISID=api-shared")
        #expect(afterResolve[0].headers["Authorization"]
            == "SAPISIDHASH 1000_h(1000 api-shared https://meet.google.com)")
        #expect(afterResolve[0].followsRedirects == false)

        try await client.invite(call, calleeID: "123", requestID: UUID())
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent[1].url.path.hasSuffix("CreateMeetingInvite"))
        #expect(sent[1].headers["x-goog-meeting-token"] == "new-token")
        #expect(sent[1].headers["Cookie"] == "SID=shared; SAPISID=api-shared")
    }

    @Test func missingTokenStopsBeforeAnyInvite() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: resolvedBody())
        ])
        let client = try makeClient(transport: transport)
        await #expect(throws: MeetCallClientError.missingMeetingToken) {
            try await client.resolve(dmID: "dm_123")
        }
        #expect(await transport.sent.count == 1)
    }

    @Test func aRotatedCookieSignsTheNextRequest() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([
                    ("x-goog-meeting-token", "new-token"),
                    ("Set-Cookie", "SAPISID=rotated; Domain=.google.com; Path=/; Secure")
                ]),
                body: resolvedBody()
            ),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data([0x0A, 0x01, 0x31]).base64Body)
        ])
        let client = try makeClient(transport: transport)
        let call = try await client.resolve(dmID: "dm_123")
        try await client.invite(call, calleeID: "123", requestID: UUID())
        let sent = await transport.sent
        #expect(sent[1].headers["Cookie"] == "SID=shared; SAPISID=rotated")
        #expect(sent[1].headers["Authorization"]
            == "SAPISIDHASH 1000_h(1000 rotated https://meet.google.com)")
    }

    @Test func missingScopedProofStopsBeforeSending() async throws {
        let transport = FakeHTTPTransport(responses: [])
        let client = try makeClient(transport: transport, cookies: [
            .init(name: "SID", value: "shared", domain: ".google.com", path: "/"),
            .init(name: "SAPISID", value: "chat-only", domain: "chat.google.com", path: "/")
        ])
        await #expect(throws: MeetCallClientError.missingSessionProof) {
            try await client.resolve(dmID: "dm_123")
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func aRefusalIsReportedWithoutRetryingOrInviting() async throws {
        let body = Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED","message":"private-sentinel"}}"#
            .utf8)
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: body)
        ])
        let client = try makeClient(transport: transport)
        await #expect(throws: MeetCallClientError.httpStatus(403, refusal: MeetCallRefusal(body: body))) {
            try await client.resolve(dmID: "dm_123")
        }
        #expect(await transport.sent.count == 1)
        #expect(MeetCallRefusal(body: body).safeDescription.contains("private-sentinel") == false)
    }

    private func makeClient(
        transport: FakeHTTPTransport, cookies provided: [SessionCookies.Cookie]? = nil
    ) throws -> MeetCallClient {
        let config = try #require(MeetCallConfiguration(
            apiKey: "public-client-key", accountIndex: 0,
            referer: URL(string: "https://meet.google.com/call?mc=synthetic")!,
            userAgent: "TestBrowser",
            rtcClientID: Data([0x08, 1, 0x10, 0, 0x18, 1]).base64EncodedString(), debugID: "test-debug"
        ))
        let cookies = try #require(SessionCookies(cookies: provided ?? [
            .init(name: "SID", value: "shared", domain: ".google.com", path: "/"),
            .init(name: "SAPISID", value: "api-shared", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat-only", domain: "chat.google.com", path: "/")
        ]))
        return MeetCallClient(
            transport: transport, credentials: SessionCredentials(cookies), configuration: config,
            sha1: { "h(\($0))" }, now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func resolvedBody() -> Data {
        let bytes = Data([0x0A, 0x0A]) + Data("spaces/abc".utf8)
            + Data([0x12, 0x0C]) + Data("abc-defg-hij".utf8)
            + Data([0x1A, 0x24]) + Data("https://meet.google.com/abc-defg-hij".utf8)
        return bytes.base64Body
    }
}

private extension Data {
    var base64Body: Data {
        Data(base64EncodedString().utf8)
    }
}

extension MeetCallClientTests {
    @Test func incomingResolutionUsesTheOfferedCodeAndItsOwnTokenWithoutDMResolution() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 200, headers: HTTPHeaders([("x-goog-meeting-token", "incoming-token")]),
            body: resolvedBody()
        )])
        let invitation = try MeetIncomingInvitation(id: "invite-secret", clientID: "receiver-secret")
        let call = try await makeClient(transport: transport).resolveIncoming(
            code: "abcdefghij",
            invitation: invitation
        )
        #expect(call.token == "incoming-token")
        #expect(call.incomingInvitation?.id == "invite-secret")
        #expect(call.incomingInvitation?.clientID == "receiver-secret")
        let request = try #require(await transport.sent.first)
        #expect(request.url.path.hasSuffix("MeetingSpaceService/ResolveMeetingSpace"))
        #expect(request.body == MeetProto.string(1, "abcdefghij"))
        #expect(Data(base64Encoded: request.headers["X-Goog-Meeting-Identifier"] ?? "")
            == MeetProto.number(1, 2) + MeetProto.string(2, "abcdefghij"))
        #expect(request.headers["x-goog-meeting-token"] == nil)
        #expect(await transport.sent.count == 1)
    }

    @Test func incomingResolutionRequiresItsTokenAndNeverRetriesAMutation() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 200, headers: HTTPHeaders([]), body: resolvedBody()
        )])
        let invitation = try MeetIncomingInvitation(id: "invite-secret", clientID: nil)
        let client = try makeClient(transport: transport)
        await #expect(throws: MeetCallClientError.missingMeetingToken) {
            try await client.resolveIncoming(code: "abcdefghij", invitation: invitation)
        }
        #expect(await transport.sent.count == 1)
    }

    @Test func receiverContextUsesDeviceRequestFieldsFourAndFiveAndIsNotLogged() throws {
        let invitation = try MeetIncomingInvitation(id: "invite-secret", clientID: "receiver-secret")
        let body = try MeetDeviceWire.create(
            space: "spaces/abc", mediaSession: "mediasessions/media", incomingInvitation: invitation
        )
        #expect(try MeetProto.text(4, body) == "invite-secret")
        #expect(try MeetProto.text(5, body) == "receiver-secret")
        #expect(try MeetProto.text(1, body) == "spaces/abc")
        #expect(!invitation.description.contains("secret"))
        let outgoing = try MeetDeviceWire.create(space: "spaces/abc", mediaSession: "mediasessions/media")
        #expect(ProtoFieldScan.payloads(ofField: 4, in: outgoing).isEmpty)
        #expect(ProtoFieldScan.payloads(ofField: 5, in: outgoing).isEmpty)
    }
}

extension MeetCallClientTests {
    @Test func resolvedReceiverInvitationReachesDeviceRegistrationWithTheFreshToken() async throws {
        let device = MeetProto.string(1, "spaces/abc/devices/one") + MeetProto.number(4, 2)
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200, headers: HTTPHeaders([("x-goog-meeting-token", "10;receiver-token")]),
                body: resolvedBody()
            ),
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: device.base64Body)
        ])
        let client = try makeClient(transport: transport)
        let call = try await client.resolveIncoming(
            code: "abcdefghij", invitation: MeetIncomingInvitation(
                id: "invite-secret",
                clientID: "receiver-secret"
            )
        )
        let session = MeetDeviceSession(client: client, call: call)
        try await session.register(mediaSession: "mediasessions/media")
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent[1].headers["x-goog-meeting-token"] == "10;receiver-token")
        let body = try #require(sent[1].body)
        #expect(try MeetProto.text(4, body) == "invite-secret")
        #expect(try MeetProto.text(5, body) == "receiver-secret")
        #expect(sent.allSatisfy { !$0.url.path.hasSuffix("CreateMeetingInvite") })
    }
}

extension MeetCallClientTests {
    @Test func canonicalAliasReplyIsBoundOnlyToItsAcceptedIncomingLookup() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 200, headers: HTTPHeaders([("x-goog-meeting-token", "10;alias-token")]),
            body: resolvedBody()
        )])
        let client = try makeClient(transport: transport)
        let call = try await client.resolveIncoming(
            code: "aliasvalue", invitation: MeetIncomingInvitation(
                id: "invite-secret",
                clientID: "context-secret"
            )
        )
        #expect(call.space.code == "abc-defg-hij")
        #expect(call.resolvesIncomingReference("aliasvalue"))
        #expect(!call.resolvesIncomingReference("otheralias"))
        #expect(!call.resolvesIncomingReference("abc-defg-hij"))
        #expect(MeetIncomingReference.diagnostic("aliasvalue", call: call)
            == "Incoming call reference: 10 bytes; bare identifier; server-resolved reference")
        #expect(MeetIncomingReference.diagnostic("otheralias", call: call).hasSuffix("no matching reference"))
    }

    @Test func outgoingResolveCannotBeUsedAsAReceiverLookupEvenWhenTheCodeMatches() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 200, headers: HTTPHeaders([("x-goog-meeting-token", "10;outgoing-token")]),
            body: resolvedBody()
        )])
        let call = try await makeClient(transport: transport).resolve(dmID: "synthetic-dm")
        #expect(!call.resolvesIncomingReference("abc-defg-hij"))
        #expect(!call.resolvesIncomingReference("abcdefghij"))
    }
}
