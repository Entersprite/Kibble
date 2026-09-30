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
