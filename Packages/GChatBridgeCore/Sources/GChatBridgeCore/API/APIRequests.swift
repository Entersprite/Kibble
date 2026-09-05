import Foundation

/// Every `/api/` request, built in one place.
///
/// The same argument as `ChannelRequests`: on a protocol whose specification is
/// a set of captures, a request that cannot be diffed against one is most of
/// the debugging story gone - so every varying part is a parameter and the
/// result is assertable as an exact string.
///
/// Shape confirmed against `client.py:598-668` and `findings.md` §3.6:
///
/// ```
/// POST {base}/api/{method}?c={n}&rt=b&alt=proto&key={apiKey}
/// content-type: application/x-protobuf
/// x-framework-xsrf-token: {token}
/// X-Goog-Encode-Response-If-Executable: base64
/// ```
public struct APIRequests: Sendable {
    /// Hardcoded in the reference since 2023 and **still valid in 2026**
    /// (§3.6). Configurable for the same reason as the client version: when it
    /// stops being valid, that should be one edit.
    public static let defaultAPIKey = "AIzaSyD7InnYR3VKdb4j2rMUEbTCIr2VyEazl6k"

    /// An `/api/` call is a request/response, not a long poll. The default 70
    /// seconds exists for a poll that is *meant* to hang, and inheriting it here
    /// would turn a dead endpoint into a 70-second stall.
    static let timeout = Duration.seconds(30)

    public let endpoints: ChatEndpoints
    public let apiKey: String

    public init(endpoints: ChatEndpoints, apiKey: String = APIRequests.defaultAPIKey) {
        self.endpoints = endpoints
        self.apiKey = apiKey
    }

    /// One call. `counter` is `c`, `body` is already-serialised protobuf.
    ///
    /// `xsrfToken` is optional and **omitted rather than empty** when absent:
    /// the reference sends no header at all when it has no token, and an empty
    /// one is a different request.
    public func request(
        method: String,
        counter: Int,
        body: Data,
        xsrfToken: String?
    ) -> HTTPRequest {
        var components = URLComponents(url: base(method), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([
            ("c", String(counter)),
            ("rt", "b"),
            ("alt", "proto"),
            ("key", apiKey)
        ])
        var fields: [(String, String)] = [
            ("content-type", "application/x-protobuf"),
            // §3.6: the response is raw binary protobuf *despite* this header.
            // Sent anyway, because it is what the reference sends and what the
            // verified run sent; the decoder accepts both encodings.
            ("X-Goog-Encode-Response-If-Executable", "base64"),
            // Chat gates on this and answers a rejection with HTTP 200 plus its
            // unsupported-browser page (§15.3). Every request, not just the
            // bootstrap.
            ("User-Agent", endpoints.userAgent)
        ]
        if let xsrfToken {
            fields.append(("x-framework-xsrf-token", xsrfToken))
        }
        return HTTPRequest(
            method: .post,
            url: components.url!,
            headers: HTTPHeaders(fields),
            body: body,
            timeout: Self.timeout,
            traceLabel: method
        )
    }

    private func base(_ method: String) -> URL {
        endpoints.base.appendingPathComponent("api").appendingPathComponent(method)
    }
}
