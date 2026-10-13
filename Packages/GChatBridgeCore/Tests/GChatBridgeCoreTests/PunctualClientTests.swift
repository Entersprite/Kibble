import Foundation
import Testing
@testable import GChatBridgeCore

/// Punctual is authenticated by the session's cookies alone, as far as the
/// capture can show (`findings.md` §47), so the client's whole job is the
/// cookie: the current one on the way out, and every rotation on the way back.
struct PunctualClientTests {
    private func credentials() -> SessionCredentials {
        SessionCredentials(SessionCookies(cookies: [SessionCookies.Cookie(name: "SIDCC", value: "old")])!)
    }

    private let request = HTTPRequest(url: URL(string: "https://chat.google.com/punctual/x")!)

    @Test func aSentRequestCarriesTheCurrentCookieAndAbsorbsTheRotation() async throws {
        let credentials = credentials()
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([("Set-Cookie", "SIDCC=new")]), body: Data())
        ])
        let client = PunctualClient(transport: transport, credentials: credentials)

        _ = try await client.send(request)

        #expect(await transport.sent.first?.headers["Cookie"] == "SIDCC=old")
        #expect(await credentials.header() == "SIDCC=new")
    }

    @Test func aStreamedRequestCarriesTheCookieAndAbsorbsTheRotation() async throws {
        let credentials = credentials()
        let transport = FakeHTTPTransport(streams: [
            .init(headers: HTTPHeaders([("Set-Cookie", "SIDCC=newer")]), chunks: [])
        ])
        let client = PunctualClient(transport: transport, credentials: credentials)

        _ = try await client.stream(request)

        #expect(await transport.sent.first?.headers["Cookie"] == "SIDCC=old")
        #expect(await credentials.header() == "SIDCC=newer")
    }
}

extension PunctualClientTests {
    @Test func signedWatchUsesOneCookieSnapshotAndScopedProof() async throws {
        let credentials = try SessionCredentials(#require(SessionCookies(cookies: [
            .init(name: "SAPISID", value: "proof-cookie", domain: ".google.com", path: "/"),
            .init(name: "PRIVATE", value: "not-for-signaler", domain: "meet.google.com", path: "/")
        ])))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
        ])
        let client = PunctualClient(
            transport: transport,
            credentials: credentials,
            authorization: { jar, url in
                SAPISIDHash.browserAuthorization(for: .init(
                    cookies: jar.cookies, url: url, origin: "https://chat.google.com", timestamp: 123
                ), sha1: { $0 == "123 proof-cookie https://chat.google.com" ? "digest" : "wrong" })
            }
        )
        _ = try await client
            .send(
                HTTPRequest(
                    url: #require(URL(string: "https://signaler-pa.clients6.google.com/punctual/x"))
                )
            )
        #expect(await transport.sent.first?.headers["Cookie"] == "SAPISID=proof-cookie")
        #expect(await transport.sent.first?.headers["Authorization"] == "SAPISIDHASH 123_digest")
    }

    @Test func missingProofDoesNotSendAWatchedRequest() async {
        let transport = FakeHTTPTransport()
        let client = PunctualClient(
            transport: transport,
            credentials: credentials(),
            authorization: { _, _ in nil }
        )
        await #expect(throws: PunctualClientError.self) { try await client.send(request) }
        #expect(await transport.sent.isEmpty)
    }
}
