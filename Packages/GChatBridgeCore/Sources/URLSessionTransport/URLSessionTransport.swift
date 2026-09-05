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
    /// Where `stream()` reports the long poll's transport-level behaviour, if
    /// anywhere. `nil` on every construction site but the one
    /// `LocalBridgeBackend.SessionHandoff` builds when `--probe=channeltrace`
    /// asked for it - see `ChannelTraceFileSink`'s own doc comment for why the
    /// conformance lives in this target rather than in `MacHost`. A `nil` sink
    /// costs `stream()` one pointer check per byte and nothing else.
    private let channelTrace: (any ChannelTraceSink)?

    /// Injectable so tests can hand in a `StubURLProtocol`-backed session, and
    /// so a host that must share a session can.
    public init(session: URLSession, channelTrace: (any ChannelTraceSink)? = nil) {
        self.session = session
        self.channelTrace = channelTrace
    }

    public convenience init(channelTrace: (any ChannelTraceSink)? = nil) {
        self.init(session: URLSession(configuration: Self.makeConfiguration()), channelTrace: channelTrace)
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
        let startedAt = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.urlRequest(from: request))
        } catch {
            // Classified here, and only here: this is the one place in the
            // package that knows the concrete error came from the URL loading
            // system, and `String(describing:)` on one of those carries the
            // failing request's URL - `key=` and `c=` included - in its
            // `userInfo`. `ProtoAPIClient.callRaw`, which never touches a
            // socket, could not make this call itself.
            let classified = Self.classify(error)
            traceUnaryCall(
                channelTrace, request, startedAt, .error(Self.safeTraceDescription(classified))
            )
            throw classified
        }
        let http = try Self.httpResponse(from: response)
        traceUnaryCall(channelTrace, request, startedAt, .completed(status: http.statusCode), data)
        return HTTPResponse(
            status: http.statusCode,
            headers: Self.headers(of: http),
            body: data,
            // After redirects, which is the point: a bounce to the accounts host
            // is how unusable credentials present themselves here.
            url: http.url
        )
    }

    // MARK: - Fire-and-forget

    /// Overrides the protocol's default. Returns as soon as this response's
    /// **headers** arrive, via the same `bytes(for:)` entry point `stream()`
    /// uses, and never awaits the body - mirroring the reference's
    /// `fetch_raw`, which returns a `ClientResponse` at headers and never
    /// reads this one's body either (`maugclib/http_utils.py:175-205`).
    ///
    /// **If the server delays the *headers*, this still waits** -
    /// `bytes(for:)` does not return until the head arrives, same as `send`
    /// and `stream`. What this removes is the other wait, the measured one:
    /// `--probe=channeltrace` found the ack's *body* held open ~64 seconds
    /// behind a head that, like every other request this transport has
    /// traced, arrived promptly. A server that stalled the head itself would
    /// still gate the caller, just for however long that stall lasted -
    /// smaller than the fault this fixes, not zero.
    ///
    /// The byte stream itself is discarded immediately (`_`), not handed to a
    /// background reader. A background `Task` iterating this same
    /// `URLSession.AsyncBytes` after this function had already returned was
    /// tried first and reproducibly crashed `LocalBridgeBackendPackageTests`
    /// with SIGSEGV on every run - measured, not theoretical, and reverted
    /// rather than chased further, since draining is a nice-to-have (a
    /// connection returned to the pool sooner) and this crash is not.
    /// Whatever happens to this response's body from here is exactly what
    /// happens in the reference: nobody reads it, and nobody explicitly
    /// closes it either.
    public func fireAndForget(_ request: HTTPRequest) async throws -> HTTPHeaders {
        let startedAt = ContinuousClock.now
        let response: URLResponse
        do {
            (_, response) = try await session.bytes(for: Self.urlRequest(from: request))
        } catch {
            let classified = Self.classify(error)
            traceUnaryCall(
                channelTrace, request, startedAt, .error(Self.safeTraceDescription(classified))
            )
            throw classified
        }
        let http = try Self.httpResponse(from: response)
        traceUnaryCall(channelTrace, request, startedAt, .completed(status: http.statusCode))
        return Self.headers(of: http)
    }

    // MARK: - Streaming

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        // Taken before the request is handed to `URLSession`, and off
        // `ContinuousClock` rather than `Date`, so a sleep/wake cycle between
        // this stream and the next cannot masquerade as (or hide) a real
        // delay - see `ChannelTraceSink`'s own doc comment.
        let openedAt = ContinuousClock.now
        channelTrace?.streamOpened(kind: request.traceLabel ?? "unlabeled", at: openedAt)
        do {
            (bytes, response) = try await session.bytes(for: Self.urlRequest(from: request))
        } catch {
            // The same reasoning as `send`, and the more important of the
            // two: this request carries the long-poll's live SID
            // (`ChannelRequests`), the poll runs for minutes, and a timeout is
            // the ordinary way it fails - so an unclassified `URLError` here
            // is the likeliest path in the whole app for a session identifier
            // to reach a screen, and from there `docs/protocol/findings.md`.
            throw Self.classify(error)
        }
        let http = try Self.httpResponse(from: response)
        let headers = Self.headers(of: http)
        channelTrace?.responseHeadReceived(
            status: http.statusCode,
            contentType: headers["Content-Type"],
            contentEncoding: headers["Content-Encoding"],
            transferEncoding: headers["Transfer-Encoding"],
            at: .now
        )
        // A fresh recorder per stream, holding this one stream's batcher and
        // running byte count - `nil` for the overwhelming majority of streams,
        // which have no `channelTrace` to report to at all.
        let recorder = channelTrace.map { StreamTraceRecorder(sink: $0) }

        return HTTPStream(
            status: http.statusCode,
            headers: headers,
            body: AsyncThrowingStream { continuation in
                let task = Task {
                    var recorder = recorder
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
                        //
                        // This same one-byte-at-a-time granularity is also
                        // what makes `channelTrace` able to see real batch
                        // boundaries at all - see `ChannelTraceBatcher`.
                        for try await byte in bytes {
                            continuation.yield(Data([byte]))
                            recorder?.byteArrived()
                        }
                        recorder?.finish(outcome: .eof)
                        continuation.finish()
                    } catch {
                        // The socket dying mid-body is the other throw site
                        // this stream owns - same request, same SID, same
                        // reason to classify before it can reach
                        // `ChannelSession.openStream`'s catch.
                        let classified = Self.classify(error)
                        recorder?.finish(outcome: .error(Self.safeTraceDescription(classified)))
                        continuation.finish(throwing: classified)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        )
    }

    /// A phrase safe to write to `ChannelTraceFileSink`'s file - never
    /// `String(describing:)` on the error itself, which for an unclassified
    /// `URLError` can carry the failing request's URL (`classify(_:)`'s own
    /// doc comment). `error` here has already been through `classify(_:)`, so
    /// the only two shapes left to name are a `ClassifiedTransportFailure`
    /// and a plain `CancellationError` from `stop()` tearing down the stream's
    /// task - anything else prints as `"unclassified"` rather than risk it.
    private static func safeTraceDescription(_ error: any Error) -> String {
        if let classified = error as? ClassifiedTransportFailure {
            return classified.reason.safeDescription
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "unclassified"
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

    /// Classifies what the URL loading system threw, so nothing above this
    /// file ever holds that error's own description.
    ///
    /// Each named code is a distinct thing to tell a person, and each wants a
    /// different retry cadence (design doc §5): connectivity, a timeout, a
    /// mid-flight drop, a name that would not resolve, a connection the
    /// network refused, and a TLS/certificate failure standing in for a
    /// captive portal, a proxy or an intercepting VPN. Every other code
    /// becomes `.other(domain:code:)`, which is still exactly as safe to
    /// print: a domain string and an integer, never request content. An
    /// error that is not a `URLError` at all (a cancellation, say) is passed
    /// through unchanged - `ProtoAPIClient.callRaw` already treats anything
    /// it cannot recognise as unclassified, which is the correct fallback
    /// here too.
    ///
    /// Internal rather than private only so `URLSessionTransportTests` can
    /// drive it directly with a synthesised `URLError`, via `@testable
    /// import`, rather than through a stubbed session for every code this
    /// maps. Same reason `LocalBridgeBackend.channelStopped` is `internal`.
    static func classify(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        let reason: TransportFailureReason = switch urlError.code {
        case .notConnectedToInternet: .notConnectedToInternet
        case .timedOut: .timedOut
        case .networkConnectionLost: .connectionLost
        case .cannotFindHost, .dnsLookupFailed: .nameResolution
        case .cannotConnectToHost: .refused
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid: .intercepted
        default: .other(domain: URLError.errorDomain, code: urlError.errorCode)
        }
        return ClassifiedTransportFailure(reason)
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

/// Reports one `send(_:)`/`fireAndForget(_:)` call to `sink`, or does
/// nothing at all when there is none - the same "a nil sink costs one
/// pointer check" contract `StreamTraceRecorder` already keeps for the long
/// poll. File-scope rather than a method on `URLSessionTransport` so the
/// class body itself stays under swiftlint's `type_body_length` ceiling.
///
/// `responseBody` is `nil` for a fire-and-forget call, which is exactly what
/// makes `ChannelTraceSink.unaryCallCompleted(...)`'s own `responseByteCount`/
/// `responseBodyShape` report `nil` too - the body genuinely was never read,
/// not merely empty.
private func traceUnaryCall(
    _ sink: (any ChannelTraceSink)?,
    _ request: HTTPRequest,
    _ startedAt: ContinuousClock.Instant,
    _ outcome: UnaryTraceOutcome,
    _ responseBody: Data? = nil
) {
    sink?.unaryCallCompleted(UnaryCallRecord(
        label: request.traceLabel ?? "unlabeled",
        method: request.method.rawValue,
        requestByteCount: request.body?.count ?? 0,
        responseByteCount: responseBody?.count,
        responseBodyShape: responseBody.map { body in
            let scan = ProtoFieldScan.fields(in: body)
            return ProtoShape(fields: scan.fields, truncated: scan.truncated)
        },
        outcome: outcome,
        duration: .now - startedAt,
        startedAt: startedAt
    ))
}

/// One stream's trace bookkeeping - its batcher plus the running byte count.
///
/// Pulled out of `stream()` itself only to keep that one function under the
/// lint's length ceiling; there is no reuse story beyond that. Never
/// constructed when `channelTrace` is `nil`, so it costs nothing on the path
/// every launch but `--probe=channeltrace` actually takes.
private struct StreamTraceRecorder {
    let sink: any ChannelTraceSink
    private var batcher = ChannelTraceBatcher()
    private var totalBytes = 0

    init(sink: any ChannelTraceSink) {
        self.sink = sink
    }

    /// One byte arrived, right now. Reports the batch it closed, if any.
    mutating func byteArrived() {
        totalBytes += 1
        if let batch = batcher.arrived(at: .now) {
            sink.batchArrived(batch)
        }
    }

    /// The stream ended - flushes whatever batch was still open, then reports
    /// the end itself, so a caller need not remember to do both in order.
    mutating func finish(outcome: ChannelTraceOutcome) {
        if let batch = batcher.flush() {
            sink.batchArrived(batch)
        }
        sink.streamEnded(outcome: outcome, totalBytes: totalBytes, at: .now)
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
