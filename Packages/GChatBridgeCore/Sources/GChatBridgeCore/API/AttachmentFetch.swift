import Foundation

/// Which rendition of an uploaded attachment to fetch.
public enum AttachmentVariant: Sendable, Hashable {
    /// Wide enough for a message bubble on a 2x display.
    case preview
    /// As large as the server will serve it.
    case original
    /// The bytes as uploaded, for a file rather than a picture
    /// (`url_type=DOWNLOAD_URL`, both references). mautrix: "usually there
    /// are 4 redirects for files" `[Verify]` for this account.
    case file
}

/// An attachment's bytes, and the chain that produced them.
public struct FetchedAttachment: Sendable, Hashable {
    public let body: Data
    /// The final hop's `Content-Type`, if it sent one.
    public let contentType: String?
    public let hops: [AttachmentHop]
    /// The final hop's `Content-Disposition`, if it sent one. Carries the file
    /// name, so it is reported by presence only.
    public let contentDisposition: String?

    public init(body: Data, contentType: String?, hops: [AttachmentHop], contentDisposition: String? = nil) {
        self.body = body
        self.contentType = contentType
        self.hops = hops
        self.contentDisposition = contentDisposition
    }
}

/// Fetches an uploaded attachment's bytes through `get_attachment_url`.
///
/// ## Why it follows redirects itself
///
/// The URL is the one both references build (purple
/// `googlechat_events.c:883-903`, mautrix `portal.py:1465-1485`), and it
/// answers with a redirect chain that leaves the chat host for
/// `googleusercontent.com`, and for files comes back again (mautrix
/// `client.py:205`: "usually there are 4 redirects for files and 1 for
/// images") `[Verify]` for this account. Each hop is requested with
/// `followsRedirects == false`, and a `https` hop on Google's own domain -
/// the chat host and its siblings - is sent whatever its own `Domain` admits
/// (`SessionCookies.Cookie.isSent(to:)`), the same way a browser would; the
/// xsrf token goes to the chat host alone. That is mautrix's rule
/// (`client.py:205-215`), made precise: it authorises any `*.google.com`
/// wholesale, but a cookie only reaches a host its own scope covers
/// (`findings.md` §52.9). `Set-Cookie` is absorbed only from a hop whose
/// request actually carried a `Cookie` field - not merely an eligible one -
/// stored where its `Domain` says, so a sibling can neither plant a cookie on
/// the chat host nor touch one it was never sent (review fix round 1,
/// Important 1).
public struct AttachmentFetch: Sendable {
    /// Requests per fetch. Ten is mautrix's bound.
    public static let maxHops = 10

    static let timeout = Duration.seconds(30)

    /// `Sec-Fetch-Site`, ordered so a chain keeps the least related value it
    /// has passed through.
    private enum FetchSite: Int, Comparable {
        case sameOrigin, sameSite, crossSite

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var header: String {
            switch self {
            case .sameOrigin: "same-origin"
            case .sameSite: "same-site"
            case .crossSite: "cross-site"
            }
        }
    }

    static let navigationAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    let transport: any HTTPTransport
    let endpoints: ChatEndpoints
    private let credentials: SessionCredentials
    private let xsrfToken: String?

    public init(
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        credentials: SessionCredentials,
        xsrfToken: String?
    ) {
        self.transport = transport
        self.endpoints = endpoints
        self.credentials = credentials
        self.xsrfToken = xsrfToken
    }

    public func fetch(
        token: String,
        contentType: String,
        variant: AttachmentVariant,
        style: RequestStyle = .app
    ) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        let walked = try await walk(
            from: firstURL(
                token: token,
                contentType: style.sendsContentType ? contentType : nil,
                variant: variant
            ),
            pageIsAnAnswer: variant == .file && Self.isPage(contentType),
            style: style
        ) { try await (transport.send($0), nil) }
        return Self.fetched(walked.response, hops: walked.hops)
    }

    /// The viewer's configuration for one upload: what Chat on the web asks
    /// for when a file is opened, rather than `get_attachment_url`
    /// (`findings.md` §52.2). Followed under the same credential rule.
    public func projectorConfig(
        token: String,
        contentType: String
    ) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        let base = endpoints.base.appendingPathComponent("api").appendingPathComponent("get_projector_config")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([
            ("content_type", contentType),
            ("attachment_token", token)
        ])
        let walked = try await walk(from: components.url!, pageIsAnAnswer: false, style: .app) {
            try await (transport.send($0), nil)
        }
        return Self.fetched(walked.response, hops: walked.hops)
    }

    /// An address Google handed out - a custom emoji's `ephemeral_url` - walked
    /// under the same rules as every fetch here: credentials by host, a
    /// sign-in redirect as a failure, at most `maxHops`.
    public func fetch(url: URL) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        let walked = try await walk(from: url, pageIsAnAnswer: false, style: .app) {
            try await (transport.send($0), nil)
        }
        return Self.fetched(walked.response, hops: walked.hops)
    }

    private static func fetched(_ response: HTTPResponse, hops: [AttachmentHop]) -> FetchedAttachment {
        FetchedAttachment(
            body: response.body,
            contentType: response.headers["Content-Type"],
            hops: hops,
            contentDisposition: response.headers["Content-Disposition"]
        )
    }

    /// The hop-by-hop walk `fetch`, `projectorConfig` and `download` all take:
    /// credentials by host, `Set-Cookie` only from a hop that was sent cookies,
    /// a sign-in redirect as a failure of its own, at most `maxHops`.
    /// `exchange` is the one difference - `send` holds a body in memory,
    /// `download` writes it to a file - and the walk deletes the file of every
    /// hop but an accepted last one.
    func walk(
        from start: URL,
        pageIsAnAnswer: Bool,
        style: RequestStyle,
        exchange: (HTTPRequest) async throws -> (HTTPResponse, URL?)
    ) async throws(AttachmentFetchFailure) -> Walked {
        var url = start
        var hops: [AttachmentHop] = []
        var site = FetchSite.sameOrigin
        while hops.count < Self.maxHops {
            site = max(site, fetchSite(url))
            let sent = try await send(url, style: style, site: site, hops: hops, exchange: exchange)
            let location = sent.response.isRedirect ? sent.response.headers["Location"] : nil
            let next = location.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            let fidelity = Self.fidelity(of: location, parsedAs: next)
            hops.append(Self.hop(
                url, sent.response.status, carriedCredentials: sent.carriedCredentials, location: fidelity
            ))
            do {
                if sent.response.isRedirect {
                    Self.discard(sent.file)
                    url = try Self.redirectTarget(next, hops: hops)
                    continue
                }
                try Self.accept(sent.response, pageIsAnAnswer: pageIsAnAnswer, hops: hops)
            } catch {
                Self.discard(sent.file)
                throw error
            }
            return Walked(response: sent.response, file: sent.file, hops: hops)
        }
        throw AttachmentFetchFailure(reason: .tooManyRedirects, hops: hops)
    }

    /// Where `walk` ends: the accepted response, the file its exchange wrote
    /// (`nil` for `send`), and every hop.
    struct Walked {
        let response: HTTPResponse
        let file: URL?
        let hops: [AttachmentHop]
    }

    static func redirectTarget(_ next: URL?, hops: [AttachmentHop]) throws(AttachmentFetchFailure) -> URL {
        guard let next else { throw AttachmentFetchFailure(reason: .redirectWithoutLocation, hops: hops) }
        if next.host() == "accounts.google.com" {
            throw AttachmentFetchFailure(reason: .signInRedirect, hops: hops)
        }
        return next
    }

    static func accept(
        _ response: HTTPResponse, pageIsAnAnswer: Bool, hops: [AttachmentHop]
    ) throws(AttachmentFetchFailure) {
        guard (200 ..< 300).contains(response.status) else {
            throw AttachmentFetchFailure(
                reason: .httpStatus(response.status), hops: hops, refusal: refusal(response)
            )
        }
        if isPage(response.headers["Content-Type"]), !pageIsAnAnswer {
            throw AttachmentFetchFailure(reason: .htmlInsteadOfAttachment, hops: hops)
        }
    }

    static func discard(_ file: URL?) {
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private struct Sent {
        let response: HTTPResponse
        let file: URL?
        let carriedCredentials: Bool
    }

    /// One hop, with a transport failure carrying the hops made before it.
    ///
    /// `carriesCookies(url)` is only *eligibility* - whether this
    /// host is a candidate for the session's cookies at all. Whether a
    /// `Cookie` field actually went out is a separate fact, read off the
    /// built request itself: an eligible host with nothing admitted for it
    /// (a legacy, chat-host-only cookie hopping to a sibling, say) sends no
    /// `Cookie` field, and that is the fact both the absorb gate and
    /// `AttachmentHop.carriedCredentials` must agree on - using eligibility
    /// for either one let a sibling's `Set-Cookie` be absorbed, and reported
    /// as credentialed, for a hop that carried no credential at all (review
    /// fix round 1, Important 1).
    private func send(
        _ url: URL,
        style: RequestStyle,
        site: FetchSite,
        hops: [AttachmentHop],
        exchange: (HTTPRequest) async throws -> (HTTPResponse, URL?)
    ) async throws(AttachmentFetchFailure) -> Sent {
        let built = await request(for: url, authorised: carriesCookies(url), style: style, site: site)
        let carriedCredentials = built.headers["Cookie"] != nil
        let response: HTTPResponse
        let file: URL?
        do {
            (response, file) = try await exchange(built)
        } catch let classified as ClassifiedTransportFailure {
            throw AttachmentFetchFailure(reason: .transport(classified.reason), hops: hops)
        } catch {
            throw AttachmentFetchFailure(reason: .transport(nil), hops: hops)
        }
        // From every hop whose request actually carried a Cookie field: each
        // lands where its Domain says, so a sibling cannot plant one on the
        // chat host, or touch a legacy cookie it was never sent (findings.md
        // §52.9; review fix round 1, Important 1).
        if carriedCredentials {
            await credentials.absorb(response.headers, from: url)
        }
        return Sent(response: response, file: file, carriedCredentials: carriedCredentials)
    }

    private static func hop(
        _ url: URL,
        _ status: Int,
        carriedCredentials: Bool,
        location: AttachmentHop.LocationFidelity?
    ) -> AttachmentHop {
        AttachmentHop(
            host: url.host() ?? "",
            status: status,
            carriedCredentials: carriedCredentials,
            pathSegments: url.pathComponents.filter { $0 != "/" },
            queryNames: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map(\.name),
            location: location
        )
    }

    /// `URL(string:)` percent-encodes what it cannot accept (a `|`, a space,
    /// a stray `%`) rather than failing, and the transport sends the parsed
    /// URL, so a changed spelling is a changed request. `nil` when there is
    /// no redirect to compare.
    private static func fidelity(of location: String?, parsedAs next: URL?) -> AttachmentHop
        .LocationFidelity? {
        guard let location, let next else { return nil }
        guard URL(string: location)?.scheme != nil else { return .relative }
        return next.absoluteString == location ? .verbatim : .reencoded
    }

    private static func refusal(_ response: HTTPResponse) -> AttachmentFetchFailure.Refusal {
        AttachmentFetchFailure.Refusal(
            contentType: response.headers["Content-Type"],
            bodyBytes: response.body.count,
            headerNames: Array(Set(response.headers.fields.map { $0.name.lowercased() })).sorted()
        )
    }

    /// A page where an attachment was expected is how an unusable session
    /// presents itself (auth failure is HTTP 200 here) - unless the upload
    /// itself is a page, which only a file download can be asked for.
    static func isPage(_ contentType: String?) -> Bool {
        contentType?.lowercased().hasPrefix("text/html") == true
    }

    /// `FIFE_URL` for a picture, `DOWNLOAD_URL` for a file (both references).
    /// The `sz` values are mautrix's for the original and a 2x bubble width
    /// for the preview `[Verify]` that the server honours them; a file has
    /// none. `content_type` is sent for both, as purple does.
    /// `contentType` is `nil` when the request style leaves it out.
    func firstURL(token: String, contentType: String?, variant: AttachmentVariant) -> URL {
        let base = endpoints.base.appendingPathComponent("api").appendingPathComponent("get_attachment_url")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = [("url_type", variant == .file ? "DOWNLOAD_URL" : "FIFE_URL")]
        if let contentType {
            items.append(("content_type", contentType))
        }
        items.append(("attachment_token", token))
        switch variant {
        case .preview: items.append(("sz", "w1024"))
        case .original: items.append(("sz", "w10000-h10000"))
        case .file: break
        }
        components.percentEncodedQuery = QueryEncoding.query(items)
        return components.url!
    }

    /// `https` on Google's own domain: the chat host and its siblings, where
    /// a file download is served (`findings.md` §52), with the label boundary
    /// `CookieScope` insists on. mautrix's rule (`client.py:205-215`); each
    /// sibling is then sent only the cookies whose domain covers it.
    /// `googleusercontent.com` is never sent anything: it signs its own URLs.
    private func carriesCookies(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return isChatHost(url) || host == "google.com" || host.hasSuffix(".google.com")
    }

    private func fetchSite(_ url: URL) -> FetchSite {
        if isChatHost(url) {
            return .sameOrigin
        }
        return carriesCookies(url) ? .sameSite : .crossSite
    }

    private func isChatHost(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == endpoints.host.host()
    }

    private func request(
        for url: URL,
        authorised: Bool,
        style: RequestStyle,
        site: FetchSite
    ) async -> HTTPRequest {
        var fields = [("User-Agent", endpoints.userAgent)]
        if isChatHost(url), let xsrfToken {
            fields.append(("x-framework-xsrf-token", xsrfToken))
        }
        if style.navigation {
            fields += [
                ("Accept", Self.navigationAccept),
                ("Sec-Fetch-Dest", "document"),
                ("Sec-Fetch-Mode", "navigate"),
                ("Sec-Fetch-Site", site.header),
                ("Sec-Fetch-User", "?1"),
                ("Upgrade-Insecure-Requests", "1")
            ]
        }
        if style.referer, carriesCookies(url), let host = endpoints.host.host() {
            fields.append(("Referer", "https://\(host)/"))
        }
        let request = HTTPRequest(
            url: url,
            headers: HTTPHeaders(fields),
            timeout: Self.timeout,
            traceLabel: "get_attachment_url",
            followsRedirects: false
        )
        guard authorised else { return request }
        return await credentials.authorising(request, withholding: isChatHost(url) ? [] : style.chatHostOnly)
    }
}
