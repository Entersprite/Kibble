import Foundation
import Testing
@testable import GChatBridgeCore

/// The first real call of the connect sequence, and the one that answers "are we
/// signed in?" — which on this protocol cannot be answered any other way,
/// because **an auth failure is HTTP 200** carrying the sign-in shell.
@Suite("Bootstrap")
struct BootstrapTests {
    static func shell(app: String) -> String {
        """
        <script nonce="x">window.WIZ_global_data = ({"qwAQke":"\(app)",\
        "SMqcke":"\(String(repeating: "t", count: 42))","cfb2h":"boq_x"});</script>
        """
    }

    static func ok(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(body.utf8))
    }

    static let cookies = SessionCookies(header: "SID=a; __Secure-1PSID=b")!

    // MARK: - The request it makes

    @Test("it asks for /mole/world under the configured account index")
    func requestsMoleWorld() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints(account: .index(0)))

        let sent = try #require(await transport.sent.first)
        #expect(sent.url.path.contains("/u/0/mole/world"))
        #expect(sent.method == .get)
    }

    /// maugclib hardcodes `/u/0`. A browser with several signed-in accounts may
    /// need a different index, and a wrong one is **indistinguishable from bad
    /// credentials** — so it is configuration, not a constant.
    @Test("no account index means no /u/N segment at all")
    func accountIndexIsConfiguration() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints(account: .none))

        let sent = try #require(await transport.sent.first)
        #expect(sent.url.path.contains("/mole/world"))
        #expect(!sent.url.path.contains("/u/"))
    }

    @Test("index 1 is honoured, not silently replaced by zero")
    func indexOneIsHonoured() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints(account: .index(1)))
        let sent = try #require(await transport.sent.first)
        #expect(sent.url.path.contains("/u/1/"))
    }

    /// The captured header goes out verbatim: every cookie, in capture order.
    @Test("the whole cookie header is sent, not a chosen subset")
    func sendsEveryCookie() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())

        let sent = try #require(await transport.sent.first)
        #expect(sent.headers["Cookie"] == "SID=a; __Secure-1PSID=b")
    }

    /// The reference implementation sends this, and the endpoint is a Gmail-hosted
    /// mole, so the referer is load-bearing rather than politeness.
    @Test("the Gmail referer is sent")
    func sendsReferer() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        let sent = try #require(await transport.sent.first)
        #expect(sent.headers["referer"] == "https://mail.google.com/")
    }

    @Test("the query carries the parameters the endpoint expects, percent-encoded")
    func queryIsEncoded() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        _ = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())

        let sent = try #require(await transport.sent.first)
        let query = try #require(sent.url.query)
        #expect(query.contains("origin=https%3A%2F%2Fmail.google.com"))
        #expect(query.contains("wfi=gtn-roster-iframe-id"))
        #expect(query.contains("shell=9"))
        // The `hs` blob is a JSON array; its brackets, quotes and commas are all
        // encoded, matching the reference implementation byte for byte. Anything
        // laxer is untested against the live server.
        #expect(query.contains("hs=%5B%22h_hs%22%2Cnull"))
        #expect(!query.contains("[\"h_hs\""))
        #expect(!query.contains(","), "commas must be encoded, as the reference does")
    }

    // MARK: - What it concludes

    @Test("a Dynamite shell reports signed in")
    func signedIn() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "DynamiteWebUi"))])
        let wiz = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        #expect(wiz.isSignedIn)
        #expect(wiz.xsrfToken?.count == 42)
    }

    /// **Does not throw.** A signed-out shell is a successful HTTP exchange
    /// carrying bad news, and the caller has to be able to tell those apart from
    /// a transport failure in order to decide between "re-acquire credentials"
    /// and "retry".
    @Test("a sign-in shell reports signed out rather than throwing")
    func signedOutIsNotAnError() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok(Self.shell(app: "AccountsSignInUi"))])
        let wiz = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        #expect(wiz.isSignedIn == false)
        #expect(wiz.signInState == .signedOut)
    }

    @Test("a non-200 status is a failure, since only 200 carries a shell to read")
    func nonSuccessThrows() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 503, headers: HTTPHeaders([]), body: Data())
        ])
        await #expect(throws: BootstrapFailure.self) {
            _ = try await Bootstrap(transport: transport)
                .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        }
    }

    /// Distinct from "signed out": the page parsed as HTML but carried no blob,
    /// which means the shell's shape changed and the protocol moved.
    @Test("a page with no WIZ blob is a distinct failure from being signed out")
    func missingBlobThrows() async throws {
        let transport = FakeHTTPTransport(responses: [Self.ok("<html>nothing</html>")])
        await #expect(throws: BootstrapFailure.noGlobalData) {
            _ = try await Bootstrap(transport: transport)
                .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        }
    }

    /// **A third outcome, observed against the live server.** Cookies that are
    /// not merely incomplete but unusable do not get Chat's own sign-in shell
    /// at all: the request is redirected to `accounts.google.com` and comes back
    /// as the generic Google sign-in page, with no `WIZ_global_data` anywhere.
    ///
    /// Reporting that as "the shell's shape has changed" would send someone
    /// hunting a protocol break when their header is simply bad, so it gets its
    /// own case.
    @Test("a redirect to the Google sign-in page is reported as bad credentials")
    func signInRedirectIsItsOwnFailure() async throws {
        let signIn = try #require(URL(string: "https://accounts.google.com/v3/signin/identifier"))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: Data("<title>Sign in - Google Accounts</title>".utf8),
                url: signIn
            )
        ])
        await #expect(throws: BootstrapFailure.signInRedirect(signIn)) {
            _ = try await Bootstrap(transport: transport)
                .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        }
    }

    /// The redirect is only a credential verdict when the blob is missing. A
    /// shell that redirected but still carried one is a live session.
    @Test("a redirect that still carries a shell is not a failure")
    func redirectWithShellIsFine() async throws {
        let elsewhere = try #require(URL(string: "https://chat.google.com/u/1/mole/world"))
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([]),
                body: Data(Self.shell(app: "DynamiteWebUi").utf8),
                url: elsewhere
            )
        ])
        let wiz = try await Bootstrap(transport: transport)
            .run(cookies: Self.cookies, endpoints: ChatEndpoints())
        #expect(wiz.isSignedIn)
    }
}
