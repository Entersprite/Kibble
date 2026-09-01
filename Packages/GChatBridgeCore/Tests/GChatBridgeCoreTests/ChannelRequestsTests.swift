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
    @Test func everyChannelRequestCarriesTheUserAgentAndChatReferer() {
        for request in [
            requests.register(),
            requests.handshake(rid: 1, zx: "z"),
            requests.acknowledge(sid: "S", aid: 0, zx: "z"),
            requests.reopen(sid: "S", aid: 0, zx: "z")
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
}
