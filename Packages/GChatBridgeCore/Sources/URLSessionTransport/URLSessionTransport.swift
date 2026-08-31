import Foundation
import GChatBridgeCore

#if canImport(FoundationNetworking)
    // On Linux the networking types live here rather than in Foundation. This
    // target is the only place in the package allowed to import it, which is
    // what bounds the port: everything else is pure.
    import FoundationNetworking
#endif

/// `HTTPTransport` over `URLSession`. **The only networking code in this
/// package.**
///
/// Everything above `HTTPTransport` — framing, the channel state machine,
/// catch-up, auth detection — is pure and tested with no socket. This file is
/// the seam's other side, and keeping it this thin is what stops the Linux
/// promise from being a claim rather than a fact.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Injectable so tests can hand in a `StubURLProtocol`-backed session, and
    /// so a host that must share a session can.
    public init(session: URLSession) {
        self.session = session
    }

    public convenience init() {
        self.init(session: URLSession(configuration: Self.makeConfiguration()))
    }

    /// The configuration this package wants when it owns the session.
    ///
    /// **All automatic cookie handling is off**, and that is a credential
    /// decision rather than a tuning one. `SessionCookies` and `CookieJar` are
    /// the only things allowed to decide what gets sent, for two reasons:
    ///
    /// - a Google session cookie is the whole account, and letting it into
    ///   `HTTPCookieStorage.shared` would publish it to everything else in the
    ///   process;
    /// - cookies the host app picked up elsewhere would silently join requests
    ///   this package believes it controls entirely, which is unreproducible by
    ///   construction.
    ///
    /// The cache is off because responses carry message content and none of it
    /// should reach disk.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    // MARK: - Unary

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: Self.urlRequest(from: request))
        let http = try Self.httpResponse(from: response)
        return HTTPResponse(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: data
        )
    }

    // MARK: - Streaming

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let (bytes, response) = try await session.bytes(for: Self.urlRequest(from: request))
        let http = try Self.httpResponse(from: response)

        return HTTPStream(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // Bytes are forwarded as they arrive, with no buffering.
                        //
                        // Buffering would be cheaper and is WRONG here: a frame
                        // is `<length>\n<payload>`, and the framer cannot emit
                        // one until its last byte lands. Holding bytes back to
                        // fill a buffer would park a delivered chat message
                        // until the *next* one arrived, which on a channel that
                        // is idle for minutes at a time is indistinguishable
                        // from the message never being delivered.
                        //
                        // Chunk boundaries are not message boundaries either
                        // way, so granularity costs only CPU, never
                        // correctness. If it ever matters, the fix is a
                        // delegate-based chunker, not a timer.
                        for try await byte in bytes {
                            continuation.yield(Data([byte]))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        )
    }

    // MARK: - Conversion

    private static func urlRequest(from request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = TimeInterval(request.timeout.components.seconds)
        for field in request.headers.fields {
            // `setValue` rather than `addValue`: a request header this package
            // builds is single-valued, and appending would produce a duplicate
            // if a caller passed the same name twice.
            urlRequest.setValue(field.value, forHTTPHeaderField: field.name)
        }
        return urlRequest
    }

    private static func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TransportFailure.notHTTP
        }
        return http
    }

    /// Rebuilds the headers, restoring the repeated `Set-Cookie` fields
    /// Foundation collapsed into one comma-joined value. The splitting itself
    /// lives in the portable core, where it can be tested without a socket.
    private static func headers(of response: HTTPURLResponse) -> HTTPHeaders {
        var collapsed: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            collapsed[name] = String(describing: value)
        }
        return HTTPHeaders(collapsed: collapsed)
    }
}

/// Failures that are this layer's own, as opposed to the ones `URLSession`
/// already reports.
public enum TransportFailure: Error, CustomStringConvertible {
    case notHTTP

    public var description: String {
        switch self {
        case .notHTTP:
            "the response was not an HTTP response"
        }
    }
}
