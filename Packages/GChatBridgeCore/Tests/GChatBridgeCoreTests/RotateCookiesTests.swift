import Foundation
import Testing
@testable import GChatBridgeCore

/// `RotateCookies`: the accounts host's refresh of the `*PSIDTS` pair, which
/// the login capture can miss (`findings.md` §52.7).
@Suite("RotateCookies")
struct RotateCookiesTests {
    static let cookieSecret = "lowercasecookiesecret"

    static func credentials() -> SessionCredentials {
        SessionCredentials(
            SessionCookies(cookies: [
                SessionCookies.Cookie(
                    name: "__Secure-1PSID",
                    value: cookieSecret,
                    domain: ".google.com",
                    path: "/"
                )
            ])!
        )
    }

    static func answer(status: Int = 200, setCookies: [String]) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: HTTPHeaders(setCookies.map { ("Set-Cookie", $0) }),
            body: Data()
        )
    }

    @Test("it is the POST third-party clients send, with the jar and no redirects")
    func requestShape() async throws {
        let transport = FakeHTTPTransport(responses: [Self.answer(setCookies: [])])
        let rotate = RotateCookies(transport: transport, userAgent: "agent", credentials: Self.credentials())
        _ = try await rotate.send()
        let sent = try #require(await transport.sent.first)
        #expect(sent.method == .post)
        #expect(sent.url.absoluteString == "https://accounts.google.com/RotateCookies")
        #expect(sent.followsRedirects == false)
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.headers["Origin"] == "https://accounts.google.com")
        #expect(sent.headers["User-Agent"] == "agent")
        #expect(sent.headers["Cookie"] == "__Secure-1PSID=\(Self.cookieSecret)")
        #expect(sent.body == Data(#"[000,"-0000000000000000000"]"#.utf8))
    }

    @Test("what it sets is absorbed into the credentials, and reported by name")
    func absorbsAndNames() async throws {
        let transport = FakeHTTPTransport(responses: [Self.answer(setCookies: [
            "__Secure-1PSIDTS=lowercasenewvalue; Domain=.google.com; Path=/; Secure; HttpOnly",
            "__Secure-3PSIDTS=lowercasenewvalue; Domain=.google.com; Path=/; Secure; HttpOnly"
        ])])
        let credentials = Self.credentials()
        let outcome = try await RotateCookies(
            transport: transport,
            userAgent: "agent",
            credentials: credentials
        )
        .send()
        #expect(outcome == RotateCookies.Outcome(
            status: 200, setCookieNames: ["__Secure-1PSIDTS", "__Secure-3PSIDTS"]
        ))
        let snapshot = try #require(await credentials.snapshot)
        #expect(snapshot["__Secure-1PSIDTS"] == "lowercasenewvalue")
        #expect(snapshot["__Secure-3PSIDTS"] == "lowercasenewvalue")
    }

    @Test("a refusal is an outcome with its status, not a throw")
    func refusalIsAnOutcome() async throws {
        let transport = FakeHTTPTransport(responses: [Self.answer(status: 401, setCookies: [])])
        let outcome = try await RotateCookies(
            transport: transport, userAgent: "agent", credentials: Self.credentials()
        ).send()
        #expect(outcome == RotateCookies.Outcome(status: 401, setCookieNames: []))
    }

    /// Final review Minor 4: a legacy cookie is host-only to the chat host,
    /// so this request carries it no `Cookie` field at all. A `Domain=
    /// .google.com` answer is exactly the scope `CookieJar.apply`'s
    /// legacy-match guard treats as covering the chat host - so only gating
    /// the absorb on the request actually having carried `Cookie` (not mere
    /// eligibility) stops this host from rotating a cookie it was never
    /// sent, the same case `AttachmentFetchCredentialTests` pins per hop.
    @Test("a legacy session sends accounts.google.com nothing, so its answer never rotates the cookie")
    func legacySessionAbsorbsNothing() async throws {
        let credentials = try SessionCredentials(#require(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SIDCC", value: "old")
        ])))
        let transport = FakeHTTPTransport(responses: [Self.answer(setCookies: [
            "SIDCC=x; Domain=.google.com; Path=/"
        ])])
        _ = try await RotateCookies(transport: transport, userAgent: "agent", credentials: credentials).send()
        #expect(await credentials.rotationCount() == 0)
        let next = try await credentials
            .authorising(HTTPRequest(url: #require(URL(string: "https://chat.google.com/"))))
        #expect(next.headers["Cookie"] == "SIDCC=old")
    }
}
