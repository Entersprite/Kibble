import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

/// Thrown by `ProtoAPIClientTests.UnclassifiedThrowingTransport` - top-level
/// rather than nested inside it, since swiftlint's `nesting` rule caps types
/// at one level deep and that transport is already nested inside the suite.
private struct UnclassifiedBoom: Error {}

@Suite("ProtoAPIClient")
struct ProtoAPIClientTests {
    private func cookies() -> SessionCookies {
        SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")])!
    }

    private func selfStatusResponse() throws -> Data {
        var response = GetSelfUserStatusResponse()
        var status = UserStatus()
        var identifier = UserId()
        identifier.id = "user-1"
        status.userID = identifier
        response.userStatus = status
        return try response.serializedBytes()
    }

    private func client(
        _ transport: FakeHTTPTransport,
        xsrfToken: String? = "tok"
    ) -> ProtoAPIClient {
        ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(cookies()),
            xsrfToken: xsrfToken
        )
    }

    private func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }

    @Test func aRawResponseDecodesIntoTheTypedResponse() async throws {
        let body = try selfStatusResponse()
        let transport = FakeHTTPTransport(responses: [ok(body)])
        let client = client(transport)
        let response = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        #expect(response.userStatus.userID.id == "user-1")
        #expect(await client.lastEncoding == .raw)
    }

    /// A refused call keeps what Google said, for a diagnostic to read: the
    /// status alone named no reason for Do not disturb's 400 (session 62).
    /// Evidence, not control flow, as `lastEncoding` is.
    @Test func aRefusedCallKeepsItsMethodStatusAndBody() async throws {
        let refusal = HTTPResponse(status: 400, headers: HTTPHeaders([]), body: Data("bad dnd".utf8))
        let client = client(FakeHTTPTransport(responses: [refusal]))
        await #expect(throws: APIFailure.httpStatus(400)) {
            _ = try await client.call(.setDndDuration, SetDndDurationRequest())
        }
        let kept = await client.lastRefusal
        #expect(kept?.method == "set_dnd_duration")
        #expect(kept?.status == 400)
        #expect(kept?.body == Data("bad dnd".utf8))
    }

    @Test func aBase64ResponseDecodesToo() async throws {
        let body = try selfStatusResponse()
        let encoded = Data(body.base64EncodedString().utf8)
        let transport = FakeHTTPTransport(responses: [ok(encoded)])
        let client = client(transport)
        let response = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        #expect(response.userStatus.userID.id == "user-1")
        #expect(await client.lastEncoding == .base64)
    }

    /// The reference initialises the counter at 0 and increments **before**
    /// formatting the URL, so the first request on the wire is c=1.
    @Test func theFirstRequestSendsCounterOne() async throws {
        let transport = try FakeHTTPTransport(responses: [ok(selfStatusResponse())])
        _ = try await client(transport).call(.getSelfUserStatus, GetSelfUserStatusRequest())
        let sent = await transport.sent
        #expect(sent.first?.url.absoluteString.contains("?c=1&") == true)
    }

    @Test func theCounterAdvancesPerCall() async throws {
        let body = try selfStatusResponse()
        let transport = FakeHTTPTransport(responses: [ok(body), ok(body)])
        let client = client(transport)
        _ = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        _ = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        let sent = await transport.sent
        #expect(sent.last?.url.absoluteString.contains("?c=2&") == true)
    }

    @Test func theLiveCookieHeaderGoesOnTheRequest() async throws {
        let transport = try FakeHTTPTransport(responses: [ok(selfStatusResponse())])
        let credentials = SessionCredentials(cookies())
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "SID=rotated")]), from: ChatEndpoints().host)
        let client = ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: credentials,
            xsrfToken: "tok"
        )
        _ = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        let sent = await transport.sent
        #expect(sent.first?.headers["Cookie"] == "SID=rotated")
    }

    @Test func setCookieOnAnAPIResponseIsAbsorbed() async throws {
        let response = try HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("Set-Cookie", "SID=fresh")]),
            body: selfStatusResponse()
        )
        let transport = FakeHTTPTransport(responses: [response])
        let credentials = SessionCredentials(cookies())
        let client = ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: credentials,
            xsrfToken: "tok"
        )
        _ = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        #expect(await credentials.header() == "SID=fresh")
    }

    /// §12.3: `Set-Cookie` rotates on every long-poll cycle, and a response
    /// that rotates a cookie and then fails still rotated it. `callRaw`
    /// absorbs headers *before* judging the status precisely so a failing
    /// call cannot leave the jar behind the server - silently, since the
    /// symptom would only surface later as an inexplicable expiry.
    @Test func aFailingResponseStillRotatesTheCookiesItCarried() async throws {
        let response = HTTPResponse(
            status: 403,
            headers: HTTPHeaders([("Set-Cookie", "SID=rotated-on-failure")]),
            body: Data()
        )
        let transport = FakeHTTPTransport(responses: [response])
        let credentials = SessionCredentials(cookies())
        let client = ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(),
            credentials: credentials,
            xsrfToken: "tok"
        )
        await #expect(throws: APIFailure.httpStatus(403)) {
            try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        }
        #expect(await credentials.header() == "SID=rotated-on-failure")
    }

    @Test func aNonSuccessStatusIsReportedFaithfully() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        ])
        await #expect(throws: APIFailure.httpStatus(403)) {
            try await client(transport).call(.getSelfUserStatus, GetSelfUserStatusRequest())
        }
    }

    @Test func anEmptyBodyIsItsOwnFailure() async throws {
        let transport = FakeHTTPTransport(responses: [ok(Data())])
        await #expect(throws: APIFailure.emptyBody) {
            try await client(transport).call(.getSelfUserStatus, GetSelfUserStatusRequest())
        }
    }

    @Test func callRawHandsBackTheBytesWithoutDecoding() async throws {
        let body = Data([0x58, 0x15]) // field 11, value 21 - §3.6's world response
        let transport = FakeHTTPTransport(responses: [ok(body)])
        let raw = try await client(transport).callRaw("paginated_world", body: Data())
        #expect(raw.status == 200)
        #expect(raw.body == body)
    }

    // MARK: - Classification

    /// A transport that has already classified its own failure - the shape
    /// `URLSessionTransport` produces once it recognises a `URLError` -
    /// carries that classification through `callRaw` untouched.
    private struct ClassifiedThrowingTransport: HTTPTransport {
        let reason: TransportFailureReason
        func send(_: HTTPRequest) async throws -> HTTPResponse {
            throw ClassifiedTransportFailure(reason)
        }

        func stream(_: HTTPRequest) async throws -> HTTPStream {
            throw ClassifiedTransportFailure(reason)
        }
    }

    /// A transport that fails with something `callRaw` cannot possibly
    /// recognise - standing in for every `HTTPTransport` conformance that
    /// cannot classify its own failures, `FakeHTTPTransport` included.
    private struct UnclassifiedThrowingTransport: HTTPTransport {
        func send(_: HTTPRequest) async throws -> HTTPResponse {
            throw UnclassifiedBoom()
        }

        func stream(_: HTTPRequest) async throws -> HTTPStream {
            throw UnclassifiedBoom()
        }
    }

    @Test func aClassifiedTransportFailureCarriesItsReasonThroughCallRaw() async {
        let client = ProtoAPIClient(
            transport: ClassifiedThrowingTransport(reason: .timedOut),
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(cookies()),
            xsrfToken: "tok"
        )
        await #expect(throws: APIFailure.transport(.timedOut)) {
            try await client.callRaw("paginated_world", body: Data())
        }
    }

    /// `callRaw` itself must never classify - only an `HTTPTransport` that
    /// actually touches a socket can - so anything it did not recognise
    /// becomes `nil`, not a guess.
    @Test func anUnclassifiableTransportFailureBecomesNilReason() async {
        let client = ProtoAPIClient(
            transport: UnclassifiedThrowingTransport(),
            endpoints: ChatEndpoints(),
            credentials: SessionCredentials(cookies()),
            xsrfToken: "tok"
        )
        await #expect(throws: APIFailure.transport(nil)) {
            try await client.callRaw("paginated_world", body: Data())
        }
    }
}
