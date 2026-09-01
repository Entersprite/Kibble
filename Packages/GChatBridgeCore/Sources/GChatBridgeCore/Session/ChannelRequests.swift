import Foundation

/// The four requests the WebChannel long-poll is made of.
///
/// Pure: every varying part — the request counter, the cache-buster, the SID,
/// the acknowledgement watermark — is a parameter rather than something read
/// from a clock or a random source here. That is what makes these assertable as
/// exact strings, which matters more than usual on a protocol whose
/// specification is a set of captures.
///
/// The parameter **order** is preserved from `findings.md` §3, which records
/// what a live server accepted. Order is unlikely to be load-bearing and is
/// free to keep, and a request that differs from a capture only by ordering is
/// harder to diff — which is the only debugging tool available here.
public struct ChannelRequests: Sendable {
    public let endpoints: ChatEndpoints

    public init(endpoints: ChatEndpoints) {
        self.endpoints = endpoints
    }

    /// The forward-channel payload carried on the first `events` call.
    ///
    /// **Already URL-encoded**, and that is the point: `%5B%5D` is `[]`. The
    /// query builder encodes it a second time, so `%255B%255D` goes on the
    /// wire. `findings.md` §3.3 calls this the single easiest detail on the
    /// protocol to get wrong, and it is invisible until the channel misbehaves
    /// — there is no complaint, the handshake simply does not do what it should.
    static let initialForwardChannelRequest = "count=1&ofs=0&req0_data=%5B%5D"

    /// The referer the channel expects. Correctly spelled, unlike the
    /// reference's `refer` on the bootstrap (§5); the correct spelling is the
    /// one that was accepted.
    static let channelReferer = "https://chat.google.com/"

    /// Opens the channel.
    ///
    /// A `Content-Type` on a bodyless GET, which looks wrong and is what the
    /// reference sends. `ignore_compass_cookie=1` is why `COMPASS` comes back
    /// rotated and longer (§12.3).
    public func register() -> HTTPRequest {
        var components = URLComponents(url: channelBase("register"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([("ignore_compass_cookie", "1")])
        return HTTPRequest(
            url: components.url!,
            headers: headers([("Content-Type", "application/x-protobuf")])
        )
    }

    /// The first `events` call, which is what mints a SID.
    ///
    /// `SID=null` is the literal four-character string — not an omitted
    /// parameter and not a JSON null. The SID comes back in the
    /// `X-HTTP-Initial-Response` header rather than the body.
    public func handshake(rid: Int, zx: String) -> HTTPRequest {
        events([
            ("VER", "8"),
            ("RID", String(rid)),
            ("t", "1"),
            ("zx", zx),
            ("CVER", "22"),
            ("$req", Self.initialForwardChannelRequest),
            ("SID", "null")
        ])
    }

    /// Tells the server the SID arrived.
    ///
    /// The reference's own comment is "I'm not sure what else this could be,
    /// but it does seem to be required", which is as much as anyone knows.
    /// `RID` is the literal string `rpc` here, not the numeric counter.
    public func acknowledge(sid: String, aid: Int, zx: String) -> HTTPRequest {
        events([
            ("VER", "8"),
            ("RID", "rpc"),
            ("SID", sid),
            ("AID", String(aid)),
            ("CI", "0"),
            ("TYPE", "xmlhttp"),
            ("zx", zx),
            ("t", "1")
        ])
    }

    /// Re-opens the long poll after the previous one ended.
    ///
    /// The poll **closes on its own within seconds** of the handshake, which is
    /// normal rather than an error (§3.5) — a client that does not loop sees
    /// only the handshake and concludes nothing is being delivered.
    ///
    /// `AID` is the highest **fully processed** array, so the server knows what
    /// not to send again.
    public func reopen(sid: String, aid: Int, zx: String) -> HTTPRequest {
        events([
            ("VER", "8"),
            ("RID", "rpc"),
            ("SID", sid),
            ("t", "1"),
            ("zx", zx),
            ("CI", "0"),
            ("TYPE", "xmlhttp"),
            ("AID", String(aid))
        ])
    }

    private func events(_ items: [(String, String)]) -> HTTPRequest {
        var components = URLComponents(url: channelBase("events"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query(items)
        return HTTPRequest(url: components.url!, headers: headers())
    }

    private func channelBase(_ path: String) -> URL {
        endpoints.base.appendingPathComponent("webchannel").appendingPathComponent(path)
    }

    /// Chat gates on the User-Agent and answers a rejected one with a 200 and
    /// its unsupported-browser page, so it belongs on every request the channel
    /// makes rather than only on the bootstrap (§15.3).
    private func headers(_ extra: [(String, String)] = []) -> HTTPHeaders {
        HTTPHeaders(
            [("referer", Self.channelReferer), ("User-Agent", endpoints.userAgent)] + extra
        )
    }
}
