import Foundation

/// What can go wrong on an `/api/` call, said precisely.
///
/// ## There is deliberately no `.notAuthenticated`
///
/// §13 established that the Chat **shell** answers an auth failure with HTTP
/// 200 carrying the sign-in page - status codes tell you nothing there. Whether
/// `/api/` behaves the same way is **unrecorded**: no run has yet put an expired
/// credential in front of it. Inventing a mapping either way would promote a
/// guess to a policy, which is the exact move that cost three cookie captures in
/// session 3. The status is surfaced and the question stays open.
public enum APIFailure: Error, Sendable, Equatable {
    /// `nil` when whatever `HTTPTransport` conformance threw could not be
    /// classified - see ``TransportFailureReason`` for who produces one and
    /// why `ProtoAPIClient.callRaw` itself never can.
    case transport(TransportFailureReason?)
    case httpStatus(Int)
    case emptyBody

    /// Every encoding that was tried, and what the last attempt said. Listing
    /// the encodings is what separates "this is not protobuf" from "this is
    /// protobuf and we read it the wrong way round".
    case undecodable(encodings: [APIResponseEncoding], detail: String)
}

public extension APIFailure {
    /// A description safe for a report that gets pasted somewhere durable -
    /// `findings.md` is the reason this exists.
    ///
    /// `.transport`'s payload is a classification `TransportFailureReason`
    /// gives no route back to the request that failed, never the error's own
    /// description - see that type's doc comment for why `callRaw` cannot
    /// classify one itself. `.undecodable`'s `detail` still comes from
    /// `String(describing:)` on a `SwiftProtobuf` decode failure, which is
    /// not a type this package controls, so it is left out here exactly as
    /// before. The case name and any value this enum itself put there (a
    /// status code, the list of encodings tried, the classification) carry
    /// the diagnosis without carrying that risk.
    var safeDescription: String {
        switch self {
        case let .transport(reason):
            if let reason {
                "transport error (\(reason.safeDescription))"
            } else {
                "transport error"
            }
        case let .httpStatus(status):
            "HTTP \(status)"
        case .emptyBody:
            "empty body"
        case let .undecodable(encodings, _):
            "undecodable (tried: \(encodings.map(\.rawValue).joined(separator: ", ")))"
        }
    }
}
