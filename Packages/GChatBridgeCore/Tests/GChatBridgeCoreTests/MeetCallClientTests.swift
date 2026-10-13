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
