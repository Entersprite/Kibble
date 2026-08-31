import Foundation
import GChatBridgeCore
import GChatBridgeCoreTestSupport
import Testing
@testable import URLSessionTransport

/// The only target in this package that touches the network, so this is the only
/// suite whose subject imports it. Everything here still runs without one:
/// `StubURLProtocol` answers the requests.
@Suite("URLSession transport")
struct URLSessionTransportTests {
    let stub = StubSession()

    var transport: URLSessionTransport {
        URLSessionTransport(session: stub.session)
    }

    // MARK: - Unary requests

    @Test("a GET returns the status and body it was given")
    func getReturnsResponse() async throws {
        stub.enqueue(.json(#"{"ok":true}"#))
        let response = try await transport.send(HTTPRequest(url: stub.baseURL))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"ok":true}"#)
    }

    @Test("request headers reach the wire")
    func requestHeadersAreSent() async throws {
        stub.enqueue(.json("{}"))
        _ = try await transport.send(
            HTTPRequest(
                url: stub.baseURL,
                headers: HTTPHeaders([("Cookie", "SID=a; SSID=b"), ("referer", "https://x/")])
            )
        )
        let sent = try #require(stub.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "SID=a; SSID=b")
        #expect(sent.value(forHTTPHeaderField: "referer") == "https://x/")
    }

    @Test("a POST body reaches the wire")
    func postBodyIsSent() async throws {
        stub.enqueue(.json("{}"))
        _ = try await transport.send(
            HTTPRequest(method: .post, url: stub.baseURL, body: Data("count=1&ofs=0".utf8))
        )
        let recorded = try #require(stub.recordings.first)
        #expect(recorded.request.httpMethod == "POST")
        #expect(try String(decoding: #require(recorded.body), as: UTF8.self) == "count=1&ofs=0")
    }

    @Test("a non-200 status is returned rather than thrown, because 200 is not success here")
    func errorStatusIsData() async throws {
        stub.enqueue(.init(status: 401, body: Data()))
        #expect(try await transport.send(HTTPRequest(url: stub.baseURL)).status == 401)
    }

    @Test("a transport failure throws")
    func failureThrows() async throws {
        // No stub queued, so StubURLProtocol fails the request.
        await #expect(throws: (any Error).self) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL))
        }
    }

    // MARK: - The cookie payoff

    /// The end-to-end reason `HTTPHeaders(collapsed:)` exists. Foundation hands
    /// back one comma-joined `Set-Cookie` field where the server sent three;
    /// this asserts the transport gives the jar all three, with the deletion's
    /// `Expires` date intact.
    @Test("three Set-Cookie headers survive Foundation collapsing them into one")
    func setCookieHeadersSurvive() async throws {
        let joined = "SIDCC=aaa; Path=/; Secure, "
            + "COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/, "
            + "__Secure-1PSIDCC=bbb; Secure; HttpOnly"
        stub.enqueue(.init(status: 200, body: Data(), headers: ["Set-Cookie": joined]))

        let response = try await transport.send(HTTPRequest(url: stub.baseURL))
        let cookies = response.headers.setCookies
        #expect(cookies.count == 3)
        #expect(cookies.first == "SIDCC=aaa; Path=/; Secure")
        // The deletion's Expires date must arrive whole - `CookieJar` decides
        // deletion from it, and that decision is asserted in the core's own
        // suite. What the transport owes is an unshredded string.
        #expect(cookies.contains("COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/"))
    }

    // MARK: - Credential custody

    /// The session must not touch the shared cookie store. Two reasons, both
    /// serious: a Google session cookie leaking into `HTTPCookieStorage.shared`
    /// would be readable by anything else in the process, and cookies the app
    /// picked up elsewhere would silently join requests this package believes it
    /// controls entirely.
    @Test("the default configuration refuses all automatic cookie handling")
    func configurationOwnsItsCookies() {
        let configuration = URLSessionTransport.makeConfiguration()
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpCookieStorage == nil)
    }

    /// Responses carry message content, so none of it should reach disk.
    @Test("the default configuration keeps no cache")
    func configurationKeepsNoCache() {
        #expect(URLSessionTransport.makeConfiguration().urlCache == nil)
    }

    // MARK: - Streaming

    /// The contract that makes the long poll possible: the head is available
    /// before the body finishes, because the SID lives in a header of a response
    /// whose body stays open for the length of the poll.
    @Test("a stream yields its head first, then the body")
    func streamHeadThenBody() async throws {
        stub.enqueue(
            .init(
                status: 200,
                body: Data("52\n[[1,[\"noop\"]]]".utf8),
                headers: ["X-HTTP-Initial-Response": #"[[0,["c","SIDVALUE"]]]"#]
            )
        )
        let stream = try await transport.stream(HTTPRequest(url: stub.baseURL))
        #expect(stream.status == 200)
        #expect(stream.headers["x-http-initial-response"] != nil)

        var body = Data()
        for try await chunk in stream.body {
            body.append(chunk)
        }
        #expect(String(decoding: body, as: UTF8.self) == "52\n[[1,[\"noop\"]]]")
    }
}
