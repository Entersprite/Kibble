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
    case transport(String)
    case httpStatus(Int)
    case emptyBody

    /// Every encoding that was tried, and what the last attempt said. Listing
    /// the encodings is what separates "this is not protobuf" from "this is
    /// protobuf and we read it the wrong way round".
    case undecodable(encodings: [APIResponseEncoding], detail: String)
}
