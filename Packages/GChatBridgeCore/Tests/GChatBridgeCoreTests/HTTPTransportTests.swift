import Foundation
import Testing
@testable import GChatBridgeCore

/// The seam that keeps this package Linux-portable: framing, the long-poll state
/// machine and catch-up talk to `HTTPTransport`, and only `URLSessionTransport`
/// imports networking. That is also why the request and response types are
/// defined here rather than reusing Foundation's — `URLRequest` and
/// `HTTPURLResponse` resolve from `FoundationNetworking` on Linux, and
/// `scripts/test.sh` fails the build if either name appears in this target.
@Suite("HTTP transport")
struct HTTPTransportTests {
    // MARK: - Headers

    /// The requirement that drives the whole type. One response rotated three
    /// cookies at once, and a `[String: String]` would have kept one and
    /// silently dropped two — a lost credential presenting as a mysterious
    /// expiry later.
    @Test("repeated header names are all preserved")
    func repeatedNamesSurvive() {
        let headers = HTTPHeaders([
            ("Set-Cookie", "SIDCC=one; Path=/"),
            ("Set-Cookie", "__Secure-1PSIDCC=two; Secure"),
            ("Content-Type", "application/json"),
            ("Set-Cookie", "__Secure-3PSIDCC=three; Secure")
        ])
        #expect(headers.all("Set-Cookie").count == 3)
        #expect(headers.setCookies.count == 3)
    }

    /// HTTP header names are case-insensitive, and servers are inconsistent
    /// about it. Matching exactly would work in tests and fail on the wire.
    @Test("lookup is case-insensitive in both directions")
    func caseInsensitiveLookup() {
        let headers = HTTPHeaders([("set-cookie", "a=1"), ("X-HTTP-Initial-Response", "[[0]]")])
        #expect(headers.all("Set-Cookie").count == 1)
        #expect(headers["x-http-initial-response"] == "[[0]]")
        #expect(headers["X-HTTP-INITIAL-RESPONSE"] == "[[0]]")
    }

    @Test("the subscript returns the first value, and nil when absent")
    func subscriptReturnsFirst() {
        let headers = HTTPHeaders([("Set-Cookie", "first=1"), ("Set-Cookie", "second=2")])
        #expect(headers["Set-Cookie"] == "first=1")
        #expect(headers["Nonexistent"] == nil)
    }

    @Test("order is preserved, because Set-Cookie order is the server's")
    func orderPreserved() {
        let headers = HTTPHeaders([("A", "1"), ("B", "2"), ("A", "3")])
        #expect(headers.all("A") == ["1", "3"])
    }

    @Test("a response with no Set-Cookie yields an empty list, not nil")
    func noCookiesIsEmpty() {
        #expect(HTTPHeaders([("Content-Type", "text/html")]).setCookies.isEmpty)
    }

    // MARK: - Headers meeting the jar

    /// The end-to-end reason all of the above matters: a response that rotates
    /// three cookies must leave the jar holding three new values.
    @Test("a response's Set-Cookie headers feed the jar in one step")
    func responseFeedsTheJar() throws {
        var jar = try CookieJar(#require(SessionCookies(header: "SID=a; SIDCC=old")))
        let response = HTTPResponse(
            status: 200,
            headers: HTTPHeaders([
                ("Set-Cookie", "SIDCC=new; Path=/; Secure"),
                ("Set-Cookie", "__Secure-1PSIDCC=fresh; Secure")
            ]),
            body: Data()
        )
        jar.absorb(setCookie: response.headers.setCookies)
        #expect(jar["SIDCC"] == "new")
        #expect(jar["__Secure-1PSIDCC"] == "fresh")
        #expect(jar.rotations.count == 2)
    }

    // MARK: - Requests

    @Test("a GET carries no body and defaults its method")
    func requestDefaults() throws {
        let request = try HTTPRequest(url: #require(URL(string: "https://chat.google.com/")))
        #expect(request.method == .get)
        #expect(request.body == nil)
    }

    // MARK: - The fake

    @Test("the fake returns scripted responses in order and records what was sent")
    func fakeIsScripted() async throws {
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data("first".utf8)),
            HTTPResponse(status: 500, headers: HTTPHeaders([]), body: Data())
        ])
        let url = try #require(URL(string: "https://example.com/a"))

        let first = try await transport.send(HTTPRequest(url: url))
        let second = try await transport.send(HTTPRequest(method: .post, url: url))

        #expect(first.status == 200)
        #expect(second.status == 500)
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent.last?.method == .post)
    }

    @Test("the fake throws once its script is exhausted rather than repeating")
    func fakeRefusesToImprovise() async throws {
        let transport = FakeHTTPTransport(responses: [])
        let url = try #require(URL(string: "https://example.com/"))
        await #expect(throws: FakeHTTPTransport.Exhausted.self) {
            try await transport.send(HTTPRequest(url: url))
        }
    }

    // MARK: - Streaming

    /// Why streaming is a separate shape rather than `send` returning `Data`:
    /// the SID arrives in the **`X-HTTP-Initial-Response` header** of a response
    /// whose body then stays open for the length of the long poll. A transport
    /// that only hands back a completed response cannot give the caller its SID
    /// until the poll ends, which is far too late.
    @Test("a stream exposes status and headers before the body completes")
    func streamHeadArrivesFirst() async throws {
        let transport = FakeHTTPTransport(streams: [
            FakeHTTPTransport.Script(
                status: 200,
                headers: HTTPHeaders([("X-HTTP-Initial-Response", #"[[0,["c","SIDVALUE"]]]"#)]),
                chunks: ["52\n[[1,[\"noop\"]]]", "40\n[[2,[\"noop\"]]]"]
            )
        ])
        let url = try #require(URL(string: "https://chat.google.com/u/0/webchannel/events"))

        let stream = try await transport.stream(HTTPRequest(url: url))
        #expect(stream.status == 200)
        #expect(stream.headers["x-http-initial-response"] != nil)

        var received: [String] = []
        for try await chunk in stream.body {
            received.append(String(decoding: chunk, as: UTF8.self))
        }
        #expect(received.count == 2)
    }
}
