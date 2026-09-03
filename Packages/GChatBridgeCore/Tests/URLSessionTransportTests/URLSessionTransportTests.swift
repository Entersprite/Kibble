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

    // MARK: - Classification

    /// Drives `URLSessionTransport.classify` directly with a synthesised
    /// `URLError`, rather than through a stubbed session - the property under
    /// test is the code-to-reason mapping itself, and this is the cheapest
    /// thing that could exercise it. `classify` is `internal` (not `private`)
    /// only so this `@testable import` can reach it.
    private func classified(_ code: URLError.Code) -> TransportFailureReason {
        guard let failure = URLSessionTransport.classify(URLError(code)) as? ClassifiedTransportFailure else {
            Issue.record("expected a ClassifiedTransportFailure for \(code)")
            return .other(domain: "unexpected", code: 0)
        }
        return failure.reason
    }

    /// Each of these is a distinct thing to tell a person, and each wants a
    /// different retry cadence - see the design doc §5. Before this they all
    /// collapsed into `.other(domain:code:)`.
    @Test func dnsFailuresAreNamed() {
        #expect(classified(.cannotFindHost) == .nameResolution)
        #expect(classified(.dnsLookupFailed) == .nameResolution)
    }

    @Test func aRefusedConnectionIsNamed() {
        #expect(classified(.cannotConnectToHost) == .refused)
    }

    /// The captive-portal / proxy / intercepting-VPN signature. Named for
    /// what is observable rather than for any of those, because nothing here
    /// distinguishes them.
    @Test func tlsFailuresAreNamedAsInterception() {
        #expect(classified(.secureConnectionFailed) == .intercepted)
        #expect(classified(.serverCertificateUntrusted) == .intercepted)
        #expect(classified(.serverCertificateHasBadDate) == .intercepted)
        #expect(classified(.serverCertificateHasUnknownRoot) == .intercepted)
        #expect(classified(.serverCertificateNotYetValid) == .intercepted)
    }

    @Test func theExistingThreeStillClassify() {
        #expect(classified(.notConnectedToInternet) == .notConnectedToInternet)
        #expect(classified(.timedOut) == .timedOut)
        #expect(classified(.networkConnectionLost) == .connectionLost)
    }

    @Test func anythingElseStaysOther() {
        #expect(classified(.userAuthenticationRequired) == .other(
            domain: URLError.errorDomain,
            code: URLError.Code.userAuthenticationRequired.rawValue
        ))
    }

    /// The whole reason `ClassifiedTransportFailure` exists: a real
    /// `URLError` here carries the failing request's URL in its own
    /// `userInfo` (`NSURLErrorFailingURLErrorKey` - `StubURLProtocol` puts one
    /// there deliberately, the way a live failure would), and the transport
    /// must classify it into a value that cannot carry that URL forward,
    /// rather than letting a caller's `String(describing:)` rediscover it.
    @Test("a not-connected URLError classifies without the request's URL")
    func notConnectedClassifies() async {
        stub.enqueueFailure(.notConnectedToInternet)
        await #expect(throws: ClassifiedTransportFailure(.notConnectedToInternet)) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL))
        }
    }

    @Test("a timed-out URLError classifies")
    func timedOutClassifies() async {
        stub.enqueueFailure(.timedOut)
        await #expect(throws: ClassifiedTransportFailure(.timedOut)) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL))
        }
    }

    @Test("a dropped-connection URLError classifies")
    func connectionLostClassifies() async {
        stub.enqueueFailure(.networkConnectionLost)
        await #expect(throws: ClassifiedTransportFailure(.connectionLost)) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL))
        }
    }

    /// A code none of the three named cases match is not discarded - it
    /// becomes `.other(domain:code:)`, still safe to print because it is a
    /// domain string and an integer, never the request that failed.
    @Test("an unrecognised URLError code classifies as .other, not silently as one of the three")
    func unrecognisedCodeClassifiesAsOther() async {
        stub.enqueueFailure(.badServerResponse)
        await #expect(
            throws: ClassifiedTransportFailure(.other(domain: URLError.errorDomain, code: -1011))
        ) {
            _ = try await transport.send(HTTPRequest(url: stub.baseURL))
        }
    }

    /// The end-to-end proof, one layer up: a real `ProtoAPIClient` call
    /// builds a URL carrying `key=` and a `c=` counter
    /// (`ProtoAPIClientTests.theFirstRequestSendsCounterOne` pins that exact
    /// shape), and a real `URLError` for that request carries the URL right
    /// back in its own `userInfo` - which is the leak `ClassifiedTransportFailure`
    /// exists to close.
    ///
    /// Written to fail on a regression, not just to pass today: if
    /// `URLSessionTransport.send` stopped classifying, or
    /// `ProtoAPIClient.callRaw` went back to `String(describing: error)`, the
    /// real `URLError` - which does carry this exact request's URL - would
    /// flow through untouched, and the three negative assertions below would
    /// catch it: the host, `key=` and `c=` would all appear in
    /// `safeDescription`.
    @Test("APIFailure.safeDescription carries the classification and never the request's URL")
    func apiFailureNeverLeaksTheRequestURL() async throws {
        stub.enqueueFailure(.notConnectedToInternet)
        let client = try ProtoAPIClient(
            transport: transport,
            endpoints: ChatEndpoints(host: #require(URL(string: "https://\(stub.host)"))),
            credentials: SessionCredentials(
                #require(SessionCookies(cookies: [SessionCookies.Cookie(name: "SID", value: "s")]))
            ),
            xsrfToken: "tok"
        )
        do {
            _ = try await client.callRaw("paginated_world", body: Data())
            Issue.record("expected callRaw to throw")
        } catch {
            guard let failure = error as? APIFailure else {
                Issue.record("expected an APIFailure, got \(type(of: error))")
                return
            }
            let description = failure.safeDescription
            #expect(description.contains("not connected to the internet"))
            #expect(!description.contains(stub.host))
            #expect(!description.contains("key="))
            #expect(!description.contains("c="))
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

    /// Fix-round finding: `send` classified a caught `URLError` and `stream`
    /// did not, even though the channel's own request carries the long
    /// poll's *live SID* directly on the query string
    /// (`ChannelRequests.reopen(sid:aid:zx:)`, verified at
    /// `ChannelRequests.swift:76,97`) and a poll that runs for minutes times
    /// out in the ordinary case, not the exceptional one - making an
    /// unclassified failure here the likeliest path in the whole app for a
    /// session identifier to reach a screen and `docs/protocol/findings.md`.
    ///
    /// The SID comes from the real production builder rather than being
    /// typed by hand; `key=` and `c=` are appended synthetically since no
    /// single channel request carries all three - the property under test is
    /// "nothing on this URL reaches the failure", not these three names
    /// specifically, and `key=`/`c=` are the two the `/api/` fix round
    /// already named.
    @Test("a stream failure classifies and never leaks the request's URL, including a live SID")
    func streamFailureNeverLeaksTheRequestURL() async throws {
        stub.enqueueFailure(.timedOut)

        let endpoints = try ChatEndpoints(host: #require(URL(string: "https://\(stub.host)")))
        let reopenRequest = ChannelRequests(endpoints: endpoints)
            .reopen(sid: "SECRET-SESSION-ID-DO-NOT-LEAK", aid: 1, zx: "zx-value")
        var components = try #require(URLComponents(url: reopenRequest.url, resolvingAgainstBaseURL: false))
        components.percentEncodedQuery = (components.percentEncodedQuery ?? "")
            + "&key=AIzaSyD7InnYR3VKdb4j2rMUEbTCIr2VyEazl6k&c=1"
        let request = try HTTPRequest(url: #require(components.url))

        do {
            _ = try await transport.stream(request)
            Issue.record("expected stream to throw")
        } catch {
            guard let failure = error as? ClassifiedTransportFailure else {
                Issue.record("expected a ClassifiedTransportFailure, got \(type(of: error))")
                return
            }
            #expect(failure.reason == .timedOut)
            // Checked on the raw `String(describing:)` output, not just
            // `.reason` - `ClassifiedTransportFailure` has no custom
            // description, so this is what a careless `\(error)` at any
            // catch site downstream would actually print.
            let description = String(describing: failure)
            #expect(!description.contains("SECRET-SESSION-ID-DO-NOT-LEAK"))
            #expect(!description.contains(stub.host))
            #expect(!description.contains("key="))
            #expect(!description.contains("c="))
        }
    }
}
