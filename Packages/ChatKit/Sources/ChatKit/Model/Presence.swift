import Foundation

/// Whether someone is around.
///
/// Open on purpose. The internal protocol's own presence enum already carries
/// values this seam does not model — `SHARING_DISABLED`, and an explicitly
/// `UNDEFINED` zero value — and a backend is expected to pass those through as
/// `.unknown(raw)` rather than guess. **[Verify]** those wire names against a
/// live account before relying on any particular one; they are read here from
/// the vendored `googlechat.proto` in this repo, not from documentation.
public enum Presence: Codable, Hashable, Sendable {
    case active
    case inactive
    case doNotDisturb
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "active": self = .active
        case "inactive": self = .inactive
        case "doNotDisturb": self = .doNotDisturb
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .doNotDisturb: "doNotDisturb"
        case let .unknown(raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(wire: WireString.decode(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try WireString.encode(wire, to: encoder)
    }
}
