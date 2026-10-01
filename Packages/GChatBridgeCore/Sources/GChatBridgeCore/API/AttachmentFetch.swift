import Foundation

/// Which rendition of an uploaded attachment to fetch.
public enum AttachmentVariant: Sendable, Hashable {
    /// Wide enough for a message bubble on a 2x display.
    case preview
    /// As large as the server will serve it.
    case original
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

    public init(body: Data, contentType: String?, hops: [AttachmentHop]) {
        self.body = body
        self.contentType = contentType
        self.hops = hops
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
            let authorised = isChatHost(url)
            let response: HTTPResponse
            do {
                response = try await transport.send(request(for: url, authorised: authorised))
            } catch let classified as ClassifiedTransportFailure {
                throw AttachmentFetchFailure(reason: .transport(classified.reason), hops: hops)
            } catch {
                throw AttachmentFetchFailure(reason: .transport(nil), hops: hops)
            }
            if authorised {
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
            if type?.lowercased().hasPrefix("text/html") == true {
                throw AttachmentFetchFailure(reason: .htmlInsteadOfAttachment, hops: hops)
            }
            return FetchedAttachment(body: response.body, contentType: type, hops: hops)
        }
        throw AttachmentFetchFailure(reason: .tooManyRedirects, hops: hops)
    }

    /// `url_type=FIFE_URL` because only images are fetched; a file would want
    /// `DOWNLOAD_URL` (both references). The `sz` values are mautrix's for the
    /// original and a 2x bubble width for the preview `[Verify]` that the
    /// server honours them.
    func firstURL(token: String, contentType: String, variant: AttachmentVariant) -> URL {
        let base = endpoints.base.appendingPathComponent("api").appendingPathComponent("get_attachment_url")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([
            ("url_type", "FIFE_URL"),
            ("content_type", contentType),
            ("attachment_token", token),
            ("sz", variant == .preview ? "w1024" : "w10000-h10000")
        ])
        return components.url!
    }

    private func isChatHost(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == endpoints.host.host()
    }

    private func request(for url: URL, authorised: Bool) async -> HTTPRequest {
        var fields = [("User-Agent", endpoints.userAgent)]
        if authorised, let xsrfToken {
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
