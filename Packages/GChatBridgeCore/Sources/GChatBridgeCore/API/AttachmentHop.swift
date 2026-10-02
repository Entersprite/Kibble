import Foundation

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
    /// For a redirect, whether the next hop asked for the `Location` exactly
    /// as sent. `nil` when this hop did not redirect to anywhere parseable.
    public let location: LocationFidelity?

    /// A names-only comparison with the browser's address (`findings.md`
    /// §52.6) cannot see a value `URL(string:)` re-encoded on the way, so
    /// this is the comparison of the values, reduced to one word.
    public enum LocationFidelity: Sendable, Hashable {
        /// Absolute, and the URL requested next spells it byte for byte.
        case verbatim
        /// Absolute, and parsing it changed its spelling.
        case reencoded
        /// Resolved against the hop's own URL, so not comparable as text.
        case relative
    }

    public init(
        host: String,
        status: Int,
        carriedCredentials: Bool,
        pathSegments: [String] = [],
        queryNames: [String] = [],
        location: LocationFidelity? = nil
    ) {
        self.host = host
        self.status = status
        self.carriedCredentials = carriedCredentials
        self.pathSegments = pathSegments
        self.queryNames = queryNames
        self.location = location
    }
}
