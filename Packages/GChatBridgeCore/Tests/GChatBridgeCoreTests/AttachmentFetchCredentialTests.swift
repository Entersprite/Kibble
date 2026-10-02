import Foundation
import Testing
@testable import GChatBridgeCore

/// `AttachmentFetch`'s credentials, hop by hop: which host is sent the
/// session's cookies, which the xsrf token, and whose `Set-Cookie` reaches the
/// jar. Split from `AttachmentFetchTests` for `type_body_length`; the fixtures
/// are that suite's.
@Suite("Attachment fetch - credentials")
struct AttachmentFetchCredentialTests {
    @Test("the chat host gets the cookie, the xsrf token and the user agent")
    func chatHostIsAuthorised() async throws {
        let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image()])
        _ = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t",
            contentType: "image/png",
            variant: .preview
        )
        let sent = try #require(await transport.sent.first)
        #expect(sent.headers["Cookie"]?.contains(AttachmentFetchTests.cookieSecret) == true)
        #expect(sent.headers["x-framework-xsrf-token"] == AttachmentFetchTests.xsrfSecret)
        #expect(sent.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
    }

    /// The rule since `findings.md` §52: the session's cookies go to `https`
    /// on Google's own domain - the chat host and its siblings, where a file
    /// download is served - and the xsrf token to the chat host alone.
    /// `googleusercontent.com` gets nothing: it signs its own URLs (§51.2).
    @Test("cookies go to https Google hosts, the xsrf token to the chat host, nothing elsewhere")
    func credentialsByHost() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            AttachmentFetchTests.redirect(to: "https://chat.google.com/api/after"),
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/download"),
            AttachmentFetchTests.redirect(to: "https://google.com/root"),
            AttachmentFetchTests.image()
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        let sent = await transport.sent
        #expect(sent.count == 5)
        let cookie = sent
            .map { $0.headers.fields.contains { $0.value.contains(AttachmentFetchTests.cookieSecret) } }
        let xsrf = sent
            .map { $0.headers.fields.contains { $0.value.contains(AttachmentFetchTests.xsrfSecret) } }
        #expect(cookie == [true, false, true, true, true])
        #expect(xsrf == [true, false, true, false, false])
        #expect(sent.allSatisfy { $0.followsRedirects == false })
        #expect(fetched.hops.map(\.carriedCredentials) == [true, false, true, true, true])
    }

    /// The label boundary `CookieScope` already insists on: a suffix match
    /// without the dot would admit a host that merely ends in "google.com".
    @Test(arguments: [
        "https://evilgoogle.com/x",
        "https://google.com.evil.example/x",
        "https://chat.google.community/x",
        "http://chat.usercontent.google.com/x"
    ])
    func lookalikesGetNothing(_ location: String) async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: location),
            AttachmentFetchTests.image()
        ])
        _ = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t",
            contentType: "image/png",
            variant: .preview
        )
        let second = try #require(await transport.sent.last)
        #expect(!second.headers.fields.contains {
            $0.value.contains(AttachmentFetchTests.cookieSecret) || $0.value
                .contains(AttachmentFetchTests.xsrfSecret)
        })
    }

    /// A sibling Google host is sent the jar, and what it sets with no
    /// `Domain` is now absorbed - but host-only, for that sibling alone
    /// (`findings.md` §52.9), so it never reaches a request to the chat host.
    @Test("a cookie a sibling sets without Domain is the sibling's, and never reaches the chat host")
    func siblingCookiesAreNotAbsorbed() async throws {
        let credentials = AttachmentFetchTests.credentials()
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/d", setCookie: nil),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([
                    ("Content-Type", "application/pdf"),
                    ("Set-Cookie", "SIBLING=x; Path=/")
                ]),
                body: Data("PDF".utf8)
            )
        ])
        _ = try await AttachmentFetchTests.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "application/pdf", variant: .file
        )
        // Positive control: the fixture's `SID` carries `Domain=.google.com`,
        // so the sibling hop does carry a Cookie field and `SIBLING` really
        // is absorbed - just host-only, to the sibling alone. Without this,
        // the assertion below would also pass if nothing were absorbed at
        // all.
        let siblingRequest = try await credentials
            .authorising(HTTPRequest(url: #require(URL(string: "https://chat.usercontent.google.com/d"))))
        #expect(siblingRequest.headers["Cookie"]?.contains("SIBLING=x") == true)
        let next = try await credentials
            .authorising(HTTPRequest(url: #require(URL(string: "https://chat.google.com/"))))
        #expect(next.headers["Cookie"]?.contains("SIBLING") != true)
    }

    /// The counterpart to the test above: a sibling's rotation of a cookie
    /// that *does* carry `Domain=.google.com` is not sibling-only - it reaches
    /// the chat host's next request, the same as a browser's cookie store
    /// would (`findings.md` §52.9). This only holds because `Set-Cookie` is
    /// absorbed from every authorised hop, not the chat host alone.
    @Test("a .google.com cookie a sibling rotates reaches the chat host's next request")
    func siblingRotationReachesChatHost() async throws {
        let credentials = AttachmentFetchTests.credentials()
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/d", setCookie: nil),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([
                    ("Content-Type", "application/pdf"),
                    ("Set-Cookie", "SIDCC=two; Domain=.google.com; Path=/")
                ]),
                body: Data("PDF".utf8)
            )
        ])
        _ = try await AttachmentFetchTests.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "application/pdf", variant: .file
        )
        let next = try await credentials
            .authorising(HTTPRequest(url: #require(URL(string: "https://chat.google.com/"))))
        #expect(next.headers["Cookie"]?.contains("SIDCC=two") == true)
    }

    /// Review fix round 1, Important 1: `authorised` (eligibility -
    /// `carriesCookies`) is not the same fact as "a `Cookie` header was
    /// actually sent". A legacy cookie is host-only to the chat host, so an
    /// eligible sibling it was never sent must not have its `Set-Cookie`
    /// absorbed - and this is the case that actually exercises the gate: a
    /// `Set-Cookie` with no `Domain` at all (the earlier draft of this test)
    /// is scoped host-only to the *sibling*, which the jar's own name+domain
    /// identity already refuses to match against the domain-less legacy
    /// cookie, so the gate was never reached and the test could not fail with
    /// it weakened to `if authorised`. A `Domain=.google.com` answer is
    /// different: `CookieJar.apply`'s legacy-scope guard treats any scope
    /// that *covers* the chat host as a match for a domain-less cookie by
    /// name, regardless of whether that scope is who the cookie was actually
    /// sent to - so only the `carriedCredentials` gate (not eligibility)
    /// stops a sibling that was never sent this cookie from rotating it.
    @Test("a legacy session sends the sibling no cookie, so its Set-Cookie never rotates the legacy one")
    func legacySiblingHopCarriesNoCookieAndAbsorbsNothing() async throws {
        let credentials = try SessionCredentials(#require(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SIDCC", value: "old")
        ])))
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/d", setCookie: nil),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([
                    ("Content-Type", "application/pdf"),
                    ("Set-Cookie", "SIDCC=x; Domain=.google.com; Path=/")
                ]),
                body: Data("PDF".utf8)
            )
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "application/pdf", variant: .file
        )
        #expect(fetched.hops[1].carriedCredentials == false)
        #expect(await credentials.rotationCount() == 0)
        let next = try await credentials
            .authorising(HTTPRequest(url: #require(URL(string: "https://chat.google.com/"))))
        #expect(next.headers["Cookie"] == "SIDCC=old")
    }

    @Test("plain http to the chat host is not the chat host")
    func insecureChatHostGetsNothing() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "http://chat.google.com/api/plain"),
            AttachmentFetchTests.image()
        ])
        _ = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t",
            contentType: "image/png",
            variant: .preview
        )
        let second = try #require(await transport.sent.last)
        #expect(second.headers["Cookie"] == nil)
        #expect(second.headers["x-framework-xsrf-token"] == nil)
    }

    @Test("a relative Location resolves against the hop that sent it")
    func relativeLocation() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            AttachmentFetchTests.redirect(to: "/fife/second"),
            AttachmentFetchTests.image()
        ])
        _ = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t",
            contentType: "image/png",
            variant: .preview
        )
        let last = try #require(await transport.sent.last)
        #expect(last.url.absoluteString == "https://lh3.googleusercontent.com/fife/second")
        #expect(last.headers["Cookie"] == nil)
    }

    @Test("a rotated cookie from the chat host is absorbed into the jar")
    func absorbsFromChatHost() async throws {
        let credentials = AttachmentFetchTests.credentials()
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife, setCookie: "SIDCC=rotated; Path=/"),
            AttachmentFetchTests.image()
        ])
        _ = try await AttachmentFetchTests.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        #expect(await credentials.header().contains("SIDCC=rotated"))
    }

    @Test("a cookie set by any other host never reaches the chat jar")
    func ignoresOtherHostsCookies() async throws {
        let credentials = AttachmentFetchTests.credentials()
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("Content-Type", "image/png"), ("Set-Cookie", "FOREIGN=x; Path=/")]),
                body: Data("PNG".utf8)
            )
        ])
        _ = try await AttachmentFetchTests.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        #expect(await !credentials.header().contains("FOREIGN"))
    }
}
