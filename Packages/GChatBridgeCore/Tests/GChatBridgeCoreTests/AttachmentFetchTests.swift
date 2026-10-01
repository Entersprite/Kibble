import Foundation
import Testing
@testable import GChatBridgeCore

/// `AttachmentFetch`: an uploaded attachment's bytes, fetched hop by hop so
/// the session's credentials go to Google's chat host and nowhere else.
@Suite("Attachment fetch")
struct AttachmentFetchTests {
    /// Lowercase on purpose. Session 36's leak test used uppercase sentinels
    /// against a printer that masked uppercase, so it could not fail; this
    /// suite masks nothing, but a sentinel that no rule treats specially is
    /// the habit `CLAUDE.md` asks for.
    static let cookieSecret = "lowercasecookiesecret"
    static let xsrfSecret = "lowercasexsrfsecret"

    static func credentials() -> SessionCredentials {
        SessionCredentials(
            SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: cookieSecret)])!
        )
    }

    static let endpoints = ChatEndpoints()

    static func fetch(_ transport: FakeHTTPTransport, credentials: SessionCredentials = credentials())
        -> AttachmentFetch {
        AttachmentFetch(
            transport: transport,
            endpoints: endpoints,
            credentials: credentials,
            xsrfToken: xsrfSecret
        )
    }

    static func redirect(to location: String, setCookie: String? = nil) -> HTTPResponse {
        var fields = [("Location", location)]
        if let setCookie {
            fields.append(("Set-Cookie", setCookie))
        }
        return HTTPResponse(status: 302, headers: HTTPHeaders(fields), body: Data())
    }

    static func image(_ bytes: String = "PNGBYTES", contentType: String = "image/png") -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("Content-Type", contentType)]),
            body: Data(bytes.utf8)
        )
    }

    static let fife = "https://lh3.googleusercontent.com/fife/abc=w1024"

    // MARK: - The request

    @Test("the first hop asks get_attachment_url for a FIFE preview of the token")
    func firstHopShape() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image()])
        _ = try await Self.fetch(transport).fetch(
            token: "tok/+=en", contentType: "image/png", variant: .preview
        )
        let sent = try #require(await transport.sent.first)
        #expect(sent.method == .get)
        #expect(sent.followsRedirects == false)
        #expect(sent.url.host() == "chat.google.com")
        #expect(sent.url.path() == "/u/0/api/get_attachment_url")
        let items = try #require(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["url_type"] == "FIFE_URL")
        #expect(query["content_type"] == "image/png")
        #expect(query["attachment_token"] == "tok/+=en")
        #expect(query["sz"] == "w1024")
    }

    @Test("the original variant asks for the full size")
    func originalSize() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image()])
        _ = try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .original)
        let sent = try #require(await transport.sent.first)
        let items = try #require(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "sz" }?.value == "w10000-h10000")
    }

    @Test("the file variant asks for the bytes as uploaded, with no size")
    func fileVariantShape() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image("PDF", contentType: "application/pdf")])
        _ = try await Self.fetch(transport).fetch(token: "t", contentType: "application/pdf", variant: .file)
        let sent = try #require(await transport.sent.first)
        let items = try #require(URLComponents(url: sent.url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["url_type"] == "DOWNLOAD_URL")
        #expect(query["content_type"] == "application/pdf")
        #expect(query["attachment_token"] == "t")
        #expect(query["sz"] == nil)
    }

    /// An uploaded web page is a file like any other; only a page where
    /// something else was expected is the sign-in shell.
    @Test("an HTML file downloaded as a file is not a failure")
    func htmlFileIsAFile() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image(
            "<html>notes</html>",
            contentType: "text/html"
        )])
        let fetched = try await Self.fetch(transport).fetch(
            token: "t",
            contentType: "text/html",
            variant: .file
        )
        #expect(fetched.body == Data("<html>notes</html>".utf8))
    }

    @Test("a page where a PDF was expected is still a failure")
    func htmlWhereAFileWasExpected() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image(
            "<html>sign in</html>",
            contentType: "text/html"
        )])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "application/pdf", variant: .file)
        }
        #expect(failure?.reason == .htmlInsteadOfAttachment)
    }

    @Test("the final hop's Content-Disposition is handed back")
    func contentDisposition() async throws {
        let transport = FakeHTTPTransport(responses: [HTTPResponse(
            status: 200,
            headers: HTTPHeaders([
                ("Content-Type", "application/pdf"),
                ("Content-Disposition", "attachment; filename=\"a.pdf\"")
            ]),
            body: Data("PDF".utf8)
        )])
        let fetched = try await Self.fetch(transport).fetch(
            token: "t",
            contentType: "application/pdf",
            variant: .file
        )
        #expect(fetched.contentDisposition == "attachment; filename=\"a.pdf\"")
    }

    @Test("no account segment when the endpoints have none")
    func noAccountSegment() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image()])
        let fetch = AttachmentFetch(
            transport: transport,
            endpoints: ChatEndpoints(account: .none),
            credentials: Self.credentials(),
            xsrfToken: nil
        )
        _ = try await fetch.fetch(token: "t", contentType: "image/png", variant: .preview)
        #expect(try #require(await transport.sent.first).url.path() == "/api/get_attachment_url")
    }

    // MARK: - Credentials, hop by hop

    @Test("the chat host gets the cookie, the xsrf token and the user agent")
    func chatHostIsAuthorised() async throws {
        let transport = FakeHTTPTransport(responses: [Self.image()])
        _ = try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        let sent = try #require(await transport.sent.first)
        #expect(sent.headers["Cookie"]?.contains(Self.cookieSecret) == true)
        #expect(sent.headers["x-framework-xsrf-token"] == Self.xsrfSecret)
        #expect(sent.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
    }

    @Test("a hop off the chat host carries no credential of any kind")
    func otherHostsGetNothing() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife),
            Self.redirect(to: "https://chat.google.com/api/after"),
            Self.redirect(to: "https://mail.google.com/elsewhere"),
            Self.image()
        ])
        let fetched = try await Self.fetch(transport).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        let sent = await transport.sent
        #expect(sent.count == 4)
        for request in sent {
            #expect(request.followsRedirects == false)
            let carries = request.headers.fields.contains {
                $0.value.contains(Self.cookieSecret) || $0.value.contains(Self.xsrfSecret)
            }
            #expect(carries == (request.url.host() == "chat.google.com"), "\(request.url.host() ?? "?")")
        }
        #expect(fetched.hops.map(\.host) == [
            "chat.google.com", "lh3.googleusercontent.com", "chat.google.com", "mail.google.com"
        ])
        #expect(fetched.hops.map(\.carriedCredentials) == [true, false, true, false])
    }

    @Test("plain http to the chat host is not the chat host")
    func insecureChatHostGetsNothing() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: "http://chat.google.com/api/plain"),
            Self.image()
        ])
        _ = try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        let second = try #require(await transport.sent.last)
        #expect(second.headers["Cookie"] == nil)
        #expect(second.headers["x-framework-xsrf-token"] == nil)
    }

    @Test("a relative Location resolves against the hop that sent it")
    func relativeLocation() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife),
            Self.redirect(to: "/fife/second"),
            Self.image()
        ])
        _ = try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        let last = try #require(await transport.sent.last)
        #expect(last.url.absoluteString == "https://lh3.googleusercontent.com/fife/second")
        #expect(last.headers["Cookie"] == nil)
    }

    @Test("a rotated cookie from the chat host is absorbed into the jar")
    func absorbsFromChatHost() async throws {
        let credentials = Self.credentials()
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife, setCookie: "SIDCC=rotated; Path=/"),
            Self.image()
        ])
        _ = try await Self.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        #expect(await credentials.header().contains("SIDCC=rotated"))
    }

    @Test("a cookie set by any other host never reaches the chat jar")
    func ignoresOtherHostsCookies() async throws {
        let credentials = Self.credentials()
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("Content-Type", "image/png"), ("Set-Cookie", "FOREIGN=x; Path=/")]),
                body: Data("PNG".utf8)
            )
        ])
        _ = try await Self.fetch(transport, credentials: credentials).fetch(
            token: "t", contentType: "image/png", variant: .preview
        )
        #expect(await !credentials.header().contains("FOREIGN"))
    }

    // MARK: - Outcomes

    @Test("the final hop's bytes and content type are returned")
    func returnsBytes() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife),
            Self.image("JPEGDATA", contentType: "image/jpeg")
        ])
        let fetched = try await Self.fetch(transport).fetch(
            token: "t", contentType: "image/jpeg", variant: .preview
        )
        #expect(fetched.body == Data("JPEGDATA".utf8))
        #expect(fetched.contentType == "image/jpeg")
        #expect(fetched.hops.map(\.status) == [302, 200])
    }

    @Test("a redirect to the sign-in page is its own failure")
    func signIn() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: "https://accounts.google.com/ServiceLogin?continue=x")
        ])
        await #expect(throws: AttachmentFetchFailure(reason: .signInRedirect, hops: [
            AttachmentHop(host: "chat.google.com", status: 302, carriedCredentials: true)
        ])) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(await transport.sent.count == 1)
    }

    @Test("ten redirects is the limit")
    func hopLimit() async throws {
        let transport = FakeHTTPTransport(
            responses: Array(repeating: Self.redirect(to: Self.fife), count: AttachmentFetch.maxHops)
        )
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(failure?.reason == .tooManyRedirects)
        #expect(failure?.hops.count == AttachmentFetch.maxHops)
        #expect(await transport.sent.count == AttachmentFetch.maxHops)
    }

    @Test("a redirect with no Location is a failure, not a hang")
    func missingLocation() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 302, headers: HTTPHeaders([]), body: Data())
        ])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(failure?.reason == .redirectWithoutLocation)
    }

    @Test("a non-2xx final status is a failure carrying the status")
    func errorStatus() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.redirect(to: Self.fife),
            HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        ])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(failure?.reason == .httpStatus(403))
        #expect(failure?.hops.map(\.status) == [302, 403])
    }

    /// Auth failure returns HTTP 200 on this protocol (`CLAUDE.md`), so a page
    /// is how an unusable session presents itself; purple drops an `<html`
    /// body for the same reason.
    @Test("an HTML page where bytes were expected is a failure")
    func htmlIsNotAnAttachment() async throws {
        let transport = FakeHTTPTransport(responses: [
            Self.image("<html>sign in</html>", contentType: "text/html; charset=utf-8")
        ])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(failure?.reason == .htmlInsteadOfAttachment)
    }

    @Test("a transport failure is reported without the error itself")
    func transportFailure() async throws {
        let transport = FakeHTTPTransport(responses: [])
        let failure = await #expect(throws: AttachmentFetchFailure.self) {
            try await Self.fetch(transport).fetch(token: "t", contentType: "image/png", variant: .preview)
        }
        #expect(failure?.reason == .transport(nil))
        #expect(failure?.hops.isEmpty == true)
    }
}
