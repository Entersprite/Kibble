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

/// One request in an attachment fetch's redirect chain. A hop's URL carries
/// the attachment token or a signed parameter, so it is never kept whole:
/// the host, the path's segments and the query's names, never a query value.
public struct AttachmentHop: Sendable, Hashable {
    public let host: String
    public let status: Int
    /// Whether this hop was sent the session's cookie and xsrf token.
    public let carriedCredentials: Bool
    /// Raw, and a segment can be an identifier: anything that prints these
    /// masks each one first (`findings.md` §52.5).
    public let pathSegments: [String]
    /// The query's parameter names, in order. Never a value.
    public let queryNames: [String]

    public init(
        host: String,
        status: Int,
        carriedCredentials: Bool,
        pathSegments: [String] = [],
        queryNames: [String] = []
    ) {
        self.host = host
        self.status = status
        self.carriedCredentials = carriedCredentials
        self.pathSegments = pathSegments
        self.queryNames = queryNames
    }
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

/// Why a fetch failed, with every hop made before it did.
public struct AttachmentFetchFailure: Error, Hashable {
    public enum Reason: Sendable, Hashable {
        /// A hop redirected to Google's sign-in page: the session is not usable.
        case signInRedirect
        /// `AttachmentFetch.maxHops` requests, and the last one still redirected.
        case tooManyRedirects
        case redirectWithoutLocation
        case httpStatus(Int)
        /// A 2xx whose body is a page. Auth failure is HTTP 200 on this
        /// protocol, so this is how an unusable session can present itself.
        case htmlInsteadOfAttachment
        /// Classified by the transport, or `nil` when it could not be. Never
        /// the error itself, whose description can carry the request's URL.
        case transport(TransportFailureReason?)
    }

    /// What a refusing hop answered with, without its body or any header
    /// value: whether it is a page, how big, and which headers it set.
    public struct Refusal: Sendable, Hashable {
        public let contentType: String?
        public let bodyBytes: Int
        /// Lowercased and sorted, once each.
        public let headerNames: [String]

        public init(contentType: String?, bodyBytes: Int, headerNames: [String]) {
            self.contentType = contentType
            self.bodyBytes = bodyBytes
            self.headerNames = headerNames
        }
    }

    public let reason: Reason
    public let hops: [AttachmentHop]
    /// Set for `.httpStatus` only.
    public let refusal: Refusal?

    public init(reason: Reason, hops: [AttachmentHop], refusal: Refusal? = nil) {
        self.reason = reason
        self.hops = hops
        self.refusal = refusal
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
/// `followsRedirects == false`, and only a hop to **`https` on the chat host**
/// is sent the session's cookie and xsrf token. That is mautrix's rule, made
/// narrower: it authorises any `*.google.com`, but the jar was scoped for the
/// chat host at capture time (`CookieScope`), so no other host is owed it.
/// `Set-Cookie` is absorbed from the chat host alone for the same reason: the
/// jar is one flat header, and a cookie another host set would be replayed
/// to the chat host.
public struct AttachmentFetch: Sendable {
    /// Requests per fetch. Ten is mautrix's bound.
    public static let maxHops = 10

    static let timeout = Duration.seconds(30)

    /// How each hop is asked. The app's style is the default; the others
    /// exist so the download probe can tell which difference from a browser
    /// `chat.usercontent.google.com` refuses (`findings.md` §52.4). Chat on
    /// the web downloads a file by navigating a new tab to it.
    public struct RequestStyle: Sendable, Hashable {
        /// A browser navigation's `Sec-Fetch-*`, `Upgrade-Insecure-Requests`
        /// and `Accept`, with `Sec-Fetch-Site` computed over the chain the
        /// way a browser computes it for a redirect.
        public var navigation: Bool
        /// `Referer: https://<chat host>/` - the origin only, which is what a
        /// browser's default referrer policy sends off-origin - to Google
        /// hosts only.
        public var referer: Bool
        /// Whether `get_attachment_url` is sent `content_type`. purple sends
        /// it; mautrix leaves it out for `DOWNLOAD_URL` (§52.1).
        public var sendsContentType: Bool

        public init(navigation: Bool = false, referer: Bool = false, sendsContentType: Bool = true) {
            self.navigation = navigation
            self.referer = referer
            self.sendsContentType = sendsContentType
        }

        public static let app = RequestStyle()
    }

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

    private let transport: any HTTPTransport
    private let endpoints: ChatEndpoints
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
        try await follow(
            from: firstURL(
                token: token,
                contentType: style.sendsContentType ? contentType : nil,
                variant: variant
            ),
            pageIsAnAnswer: variant == .file && Self.isPage(contentType),
            style: style
        )
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
        return try await follow(from: components.url!, pageIsAnAnswer: false, style: .app)
    }

    /// Every hop by hand: credentials by host, `Set-Cookie` from the chat
    /// host only, a sign-in redirect as a failure of its own.
    /// `pageIsAnAnswer` is whether a `text/html` body is what was asked for.
    private func follow(
        from start: URL,
        pageIsAnAnswer: Bool,
        style: RequestStyle
    ) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        var url = start
        var hops: [AttachmentHop] = []
        var site = FetchSite.sameOrigin
        while hops.count < Self.maxHops {
            let authorised = carriesCookies(url)
            site = max(site, fetchSite(url))
            let response: HTTPResponse
            do {
                response = try await transport.send(request(
                    for: url, authorised: authorised, style: style, site: site
                ))
            } catch let classified as ClassifiedTransportFailure {
                throw AttachmentFetchFailure(reason: .transport(classified.reason), hops: hops)
            } catch {
                throw AttachmentFetchFailure(reason: .transport(nil), hops: hops)
            }
            if isChatHost(url) {
                await credentials.absorb(response.headers)
            }
            hops.append(Self.hop(url, response.status, authorised: authorised))

            if response.isRedirect {
                guard let location = response.headers["Location"],
                      let next = URL(string: location, relativeTo: url)?.absoluteURL
                else {
                    throw AttachmentFetchFailure(reason: .redirectWithoutLocation, hops: hops)
                }
                if next.host() == "accounts.google.com" {
                    throw AttachmentFetchFailure(reason: .signInRedirect, hops: hops)
                }
                url = next
                continue
            }
            guard (200 ..< 300).contains(response.status) else {
                throw AttachmentFetchFailure(
                    reason: .httpStatus(response.status), hops: hops, refusal: Self.refusal(response)
                )
            }
            let type = response.headers["Content-Type"]
            if Self.isPage(type), !pageIsAnAnswer {
                throw AttachmentFetchFailure(reason: .htmlInsteadOfAttachment, hops: hops)
            }
            return FetchedAttachment(
                body: response.body,
                contentType: type,
                hops: hops,
                contentDisposition: response.headers["Content-Disposition"]
            )
        }
        throw AttachmentFetchFailure(reason: .tooManyRedirects, hops: hops)
    }

    private static func hop(_ url: URL, _ status: Int, authorised: Bool) -> AttachmentHop {
        AttachmentHop(
            host: url.host() ?? "",
            status: status,
            carriedCredentials: authorised,
            pathSegments: url.pathComponents.filter { $0 != "/" },
            queryNames: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map(\.name)
        )
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
    private static func isPage(_ contentType: String?) -> Bool {
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
    /// `CookieScope` insists on. mautrix's rule (`client.py:205-215`); a
    /// browser would send each sibling only the cookies whose domain covers
    /// it, but the jar no longer knows domains, so it is the whole jar.
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
        return authorised ? await credentials.authorising(request) : request
    }
}
