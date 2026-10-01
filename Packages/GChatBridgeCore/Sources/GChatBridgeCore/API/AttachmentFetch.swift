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

/// One request in an attachment fetch's redirect chain. Hosts and statuses
/// only: a hop's URL carries the attachment token or a signed parameter, so
/// it is never kept.
public struct AttachmentHop: Sendable, Hashable {
    public let host: String
    public let status: Int
    /// Whether this hop was sent the session's cookie and xsrf token.
    public let carriedCredentials: Bool

    public init(host: String, status: Int, carriedCredentials: Bool) {
        self.host = host
        self.status = status
        self.carriedCredentials = carriedCredentials
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

    public let reason: Reason
    public let hops: [AttachmentHop]

    public init(reason: Reason, hops: [AttachmentHop]) {
        self.reason = reason
        self.hops = hops
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
        variant: AttachmentVariant
    ) async throws(AttachmentFetchFailure) -> FetchedAttachment {
        var url = firstURL(token: token, contentType: contentType, variant: variant)
        var hops: [AttachmentHop] = []
        while hops.count < Self.maxHops {
            let authorised = carriesCookies(url)
            let response: HTTPResponse
            do {
                response = try await transport.send(request(for: url, authorised: authorised))
            } catch let classified as ClassifiedTransportFailure {
                throw AttachmentFetchFailure(reason: .transport(classified.reason), hops: hops)
            } catch {
                throw AttachmentFetchFailure(reason: .transport(nil), hops: hops)
            }
            if isChatHost(url) {
                await credentials.absorb(response.headers)
            }
            hops.append(AttachmentHop(
                host: url.host() ?? "", status: response.status, carriedCredentials: authorised
            ))

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
                throw AttachmentFetchFailure(reason: .httpStatus(response.status), hops: hops)
            }
            let type = response.headers["Content-Type"]
            if Self.isPage(type), !(variant == .file && Self.isPage(contentType)) {
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
    func firstURL(token: String, contentType: String, variant: AttachmentVariant) -> URL {
        let base = endpoints.base.appendingPathComponent("api").appendingPathComponent("get_attachment_url")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = [
            ("url_type", variant == .file ? "DOWNLOAD_URL" : "FIFE_URL"),
            ("content_type", contentType),
            ("attachment_token", token)
        ]
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

    private func isChatHost(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == endpoints.host.host()
    }

    private func request(for url: URL, authorised: Bool) async -> HTTPRequest {
        var fields = [("User-Agent", endpoints.userAgent)]
        if isChatHost(url), let xsrfToken {
            fields.append(("x-framework-xsrf-token", xsrfToken))
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
