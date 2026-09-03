import Foundation

/// A transport failure's shape, with nothing in it that could be a URL, a
/// cookie or a token.
///
/// An `HTTPTransport` conformance that can tell *why* a request failed - a
/// socket that never connected, one that timed out, one that dropped mid
/// flight - classifies it into one of these and throws
/// ``ClassifiedTransportFailure`` instead of its own concrete error.
/// `ProtoAPIClient.callRaw` reads only this, never `String(describing:)` on
/// the error it caught, which is what keeps the failing request's URL - and
/// the `key=`/`c=` query items on it - out of `APIFailure.safeDescription`
/// and everything that prints it.
///
/// `Hashable`, not just `Equatable`: `ChannelFailure` is `Hashable` and now
/// carries this as `.transport`'s payload, so this type has to be too.
public enum TransportFailureReason: Sendable, Hashable {
    case notConnectedToInternet
    case timedOut
    case connectionLost
    /// DNS did not resolve.
    case nameResolution
    /// The network was reached; the connection was refused.
    case refused
    /// TLS or certificate failure - a captive portal, a proxy or an
    /// intercepting VPN. Deliberately not named as any of them: nothing here
    /// distinguishes them, and a confidently wrong diagnosis on screen is
    /// worse than an honest vague one.
    case intercepted
    /// Whatever the cases above did not match, kept as the domain and
    /// code a classifier actually found. Both are diagnostic - never request
    /// content - which is what makes carrying them safe where carrying the
    /// error's own description would not be.
    case other(domain: String, code: Int)

    /// A phrase safe to print anywhere, including a report pasted into
    /// `findings.md`.
    public var safeDescription: String {
        switch self {
        case .notConnectedToInternet: "not connected to the internet"
        case .timedOut: "timed out"
        case .connectionLost: "network connection lost"
        case .nameResolution: "could not look up the host"
        case .refused: "the connection was refused"
        case .intercepted: "the secure connection failed"
        case let .other(domain, code): "\(domain) \(code)"
        }
    }
}

/// Thrown by an `HTTPTransport` conformance in place of whatever concrete
/// error its own transport stack raised, once that error has been classified.
///
/// This is the seam that lets `ProtoAPIClient` - which must stay portable and
/// must never import networking - carry a diagnosis without carrying the
/// error that produced it: only a conformance that actually touches a socket
/// (`URLSessionTransport`, today) constructs one of these, and everything
/// above it reads `reason` and nothing else.
public struct ClassifiedTransportFailure: Error, Sendable, Equatable {
    public let reason: TransportFailureReason

    public init(_ reason: TransportFailureReason) {
        self.reason = reason
    }
}
