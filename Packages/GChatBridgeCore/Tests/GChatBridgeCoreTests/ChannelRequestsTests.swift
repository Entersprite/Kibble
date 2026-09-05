import Foundation
import Testing
@testable import GChatBridgeCore

/// The four requests the channel makes, asserted as exact URLs.
///
/// Exact on purpose. `findings.md` §3 records these as byte-for-byte what a live
/// server accepted, and the only debugging tool available on an undocumented
/// protocol is diffing a request against a capture. A test that checked "the
/// query contains VER=8" would pass for a request the server rejects.
struct ChannelRequestsTests {
    private let requests = ChannelRequests(endpoints: ChatEndpoints())

    private func query(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    // MARK: - Register

    @Test func registerIgnoresTheCompassCookie() {
        let request = requests.register()
        #expect(
            request.url.absoluteString
                == "https://chat.google.com/u/0/webchannel/register?ignore_compass_cookie=1"
        )
        #expect(request.method == .get)
    }

    /// A `Content-Type` on a GET with no body. It looks wrong and the reference
    /// sends it, so it is sent.
    @Test func registerCarriesAProtobufContentTypeOnABodylessGet() {
        let request = requests.register()
        #expect(request.headers["Content-Type"] == "application/x-protobuf")
        #expect(request.body == nil)
    }

    // MARK: - The handshake

    @Test func theHandshakeSendsTheFirstCallParametersInOrder() {
        let url = requests.handshake(rid: 12345, zx: "abc123").url
        #expect(
            query(url)
                == "VER=8&RID=12345&t=1&zx=abc123&CVER=22"
                + "&%24req=count%3D1%26ofs%3D0%26req0_data%3D%255B%255D&SID=null"
        )
    }

    /// **The single easiest detail on this protocol to get wrong** (§3.3), and
    /// it is invisible until the channel misbehaves.
    ///
    /// The literal value is already URL-encoded: `req0_data=%5B%5D`, where
    /// `%5B%5D` is `[]`. Encoding it once more for the query is what puts
    /// `%255B%255D` on the wire. A client that encodes only once sends a
    /// different request, and gets no useful complaint about it.
    @Test func theReqParameterIsDoublePercentEncoded() {
        let url = requests.handshake(rid: 1, zx: "z").url
        #expect(query(url).contains("%24req=count%3D1%26ofs%3D0%26req0_data%3D%255B%255D"))
        // Encoded once would leave the brackets as %5B%5D.
        #expect(!query(url).contains("req0_data%3D%5B%5D"))
    }

    /// `SID=null` is the literal four-character string, not an omitted
    /// parameter and not a JSON null.
    @Test func theHandshakeSendsSIDAsTheStringNull() {
        #expect(query(requests.handshake(rid: 1, zx: "z").url).contains("&SID=null"))
    }

    // MARK: - Ack and reopen

    @Test func theAckUsesTheLiteralRidRpc() {
        let url = requests.acknowledge(sid: "S1D", aid: 0, zx: "zz").url
        #expect(query(url) == "VER=8&RID=rpc&SID=S1D&AID=0&CI=0&TYPE=xmlhttp&zx=zz&t=1")
    }

    @Test func theReopenSendsTheHighestProcessedAid() {
        let url = requests.reopen(sid: "S1D", aid: 42, zx: "yy").url
        #expect(query(url) == "VER=8&RID=rpc&SID=S1D&t=1&zx=yy&CI=0&TYPE=xmlhttp&AID=42")
    }

    /// A SID is server-supplied text interpolated into a URL, so it is encoded
    /// rather than trusted to be safe.
    @Test func aSIDWithAwkwardCharactersIsEncoded() {
        let url = requests.reopen(sid: "a b&c", aid: 0, zx: "z").url
        #expect(query(url).contains("SID=a%20b%26c"))
    }

    // MARK: - Headers every channel request carries

    /// Chat gates on the User-Agent and answers a rejected one with a 200 and
    /// its unsupported-browser page (§15.3), so this belongs on every request
    /// rather than only on the bootstrap.
    @Test func everyChannelRequestCarriesTheUserAgentAndChatReferer() throws {
        let ping = try #require(requests.ping(sid: "S", aid: 0, rid: 1, ofs: 0))
        for request in [
            requests.register(),
            requests.handshake(rid: 1, zx: "z"),
            requests.acknowledge(sid: "S", aid: 0, zx: "z"),
            requests.reopen(sid: "S", aid: 0, zx: "z"),
            ping
        ] {
            #expect(request.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
            #expect(request.headers["referer"] == "https://chat.google.com/")
        }
    }

    /// Correctly spelled, unlike the reference's `refer` on the bootstrap
    /// (§5). The correct spelling was the one accepted.
    @Test func theRefererIsSpelledCorrectly() {
        #expect(requests.handshake(rid: 1, zx: "z").headers["refer"] == nil)
    }

    // MARK: - The account index is configuration

    @Test func theAccountIndexReachesTheChannelURLs() {
        let second = ChannelRequests(endpoints: ChatEndpoints(account: .index(2)))
        #expect(second.register().url.path == "/u/2/webchannel/register")
        #expect(second.handshake(rid: 1, zx: "z").url.path == "/u/2/webchannel/events")
    }

    @Test func anAccountWithNoIndexHasNoSegment() {
        let none = ChannelRequests(endpoints: ChatEndpoints(account: .none))
        #expect(none.register().url.path == "/webchannel/register")
    }

    // MARK: - The long poll holds the response open

    /// A reopen is a long poll: it is meant to sit there. The default timeout
    /// is generous for exactly this, and shortening it would look like a
    /// server that keeps hanging up.
    @Test func aReopenIsAllowedToWait() {
        #expect(requests.reopen(sid: "S", aid: 0, zx: "z").timeout >= .seconds(60))
    }

    // MARK: - Trace labels never change what is on the wire

    /// `traceLabel` is diagnostic metadata for `ChannelTraceSink` alone - see
    /// `HTTPTransport.swift`'s own doc comment on the field. These pin which
    /// two requests carry one, matching `ChannelEffect.handshake`/`.reopen`
    /// exactly, without touching a single assertion above that already pins
    /// the exact bytes each request puts on the wire.
    @Test func theHandshakeIsLabelledForTracing() {
        #expect(requests.handshake(rid: 1, zx: "z").traceLabel == "handshake")
    }

    @Test func theReopenIsLabelledForTracing() {
        #expect(requests.reopen(sid: "S", aid: 0, zx: "z").traceLabel == "reopen")
    }

    /// Widened once the `/api/` trace needed every unary and fire-and-forget
    /// call identified the same way streams already were - `register` and
    /// `acknowledge` used to carry no label at all.
    @Test func registerAndAcknowledgeAreLabelledForTracing() {
        #expect(requests.register().traceLabel == "register")
        #expect(requests.acknowledge(sid: "S", aid: 0, zx: "z").traceLabel == "acknowledge")
    }

    @Test func thePingIsLabelledForTracing() throws {
        let ping = try #require(requests.ping(sid: "S", aid: 0, rid: 1, ofs: 0))
        #expect(ping.traceLabel == "ping")
    }

    // MARK: - The initial ping

    /// The query parameters `send_stream_event` builds (`channel.py:304-311`),
    /// in order. **`CI` is absent** - the reference's own comment reads "No
    /// longer required with the web ui", and it is commented out there, not
    /// merely defaulted to some value; a client that still sends it differs
    /// from what the reference actually puts on the wire.
    @Test func thePingSendsItsQueryParametersInOrderWithNoCI() throws {
        let ping = try #require(requests.ping(sid: "abc", aid: 3, rid: 5, ofs: 0))
        let url = ping.url
        #expect(query(url) == "VER=8&RID=5&t=1&SID=abc&AID=3")
        #expect(!query(url).contains("CI"))
    }

    @Test func thePingIsAPostWithAFormEncodedContentType() throws {
        let request = try #require(requests.ping(sid: "abc", aid: 0, rid: 1, ofs: 0))
        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
    }

    /// The body's three fields, exact: `count=1`, `ofs=<ofs>`, and
    /// `req0_data=` the pblite-encoded `StreamEventsRequest(ping_event:)` the
    /// reference builds (`channel.py:347-354`) - `state: ACTIVE`,
    /// `application_focus_state: FOCUS_STATE_FOREGROUND`,
    /// `client_interactive_state: INTERACTIVE`,
    /// `client_notifications_enabled: true` - which is field 2 of
    /// `StreamEventsRequest` (`ping_event`), itself `[1,null,1,null,1,true]`
    /// (fields 1, 3, 5, 6 of `PingEvent`; 2 and 4 are unset).
    @Test func thePingBodyIsTheExactThreeFormFields() throws {
        let request = try #require(requests.ping(sid: "abc", aid: 0, rid: 1, ofs: 0))
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(
            body == "count=1&ofs=0"
                + "&req0_data=%5Bnull%2C%5B1%2Cnull%2C1%2Cnull%2C1%2Ctrue%5D%5D"
        )
    }

    /// `RID` and `ofs` are independent parameters, not one derived from the
    /// other: changing one changes only the part of the request it belongs
    /// to (RID the query, ofs the body), and it is the *driver*'s job
    /// (`ChannelSession.requestIdentifier`/`streamEventOfs`) to keep them
    /// that way at runtime - this only pins that the builder itself never
    /// conflates them.
    @Test func ridAndOfsAreIndependentParameters() throws {
        let sameRidDifferentOfs = try #require(requests.ping(sid: "s", aid: 0, rid: 5, ofs: 0))
        let alsoSameRid = try #require(requests.ping(sid: "s", aid: 0, rid: 5, ofs: 7))
        #expect(query(sameRidDifferentOfs.url) == query(alsoSameRid.url))
        #expect(sameRidDifferentOfs.body != alsoSameRid.body)

        let sameOfsDifferentRid = try #require(requests.ping(sid: "s", aid: 0, rid: 9, ofs: 0))
        #expect(sameRidDifferentOfs.body == sameOfsDifferentRid.body)
        #expect(query(sameRidDifferentOfs.url) != query(sameOfsDifferentRid.url))
    }
}
