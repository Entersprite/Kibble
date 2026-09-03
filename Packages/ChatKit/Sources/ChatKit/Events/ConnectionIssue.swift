import Foundation

/// Why a connection is not working, in terms a UI can act on.
///
/// **Nothing in this type can be a URL, a cookie or a token.** It is built
/// from `GChatBridgeCore`'s `TransportFailureReason`, which exists for the
/// same reason and says so at length; `status` is an integer and safe to print
/// into `findings.md`.
///
/// ## Why this is a second taxonomy rather than the core's own
///
/// `GChatBridgeCore` never imports `ChatKit`, so the transport cannot produce
/// one of these and the channel's reducer cannot branch on one.
/// `LocalBridgeBackend` translates, behind an exhaustive `switch` so that a
/// new `TransportFailureReason` case stops compiling until someone decides
/// what it means here. See the design doc §4.2 and §5.0.
///
/// ## What is deliberately absent
///
/// No `captivePortal` and no `vpn`. A TLS failure is *suggestive* of either
/// and proves neither, and a VPN that merely routes traffic leaves no
/// signature at all. `.intercepted` is the honest name for what is actually
/// observable. Likewise nothing distinguishes "Google is down" from "your
/// network is blocking Google" - a timeout is byte-identical for both - which
/// is why `.unresponsive` says only that.
public enum ConnectionIssue: Codable, Hashable, Sendable {
    /// The device says there is no network. The one case a reachability
    /// monitor can answer precisely, and therefore the only one that waits
    /// for a signal rather than a clock.
    case noInternet
    /// DNS did not resolve.
    case nameResolution
    /// The network was reached and the connection was refused.
    case refused
    /// TLS or certificate failure. A captive portal, a proxy or an
    /// intercepting VPN all look like this, and nothing here tells them apart.
    case intercepted
    /// Timed out. Whose fault it is is not knowable from here.
    case unresponsive
    /// The connection was lost mid-stream. **A failure, not a healthy poll
    /// ending** - a body that *ends* is proof the channel worked, a connection
    /// *lost* is not, and conflating them is what once made a retry loop
    /// unbounded.
    case dropped
    case rateLimited
    case serverError(status: Int)
    /// An issue this build does not know. Decoded from an unrecognised
    /// discriminator and re-encoded verbatim, per this repo's wire rules.
    case unknown(String)
}

extension ConnectionIssue {
    enum CodingKeys: String, CodingKey {
        case type
        case status
    }

    enum Tag: String {
        case noInternet
        case nameResolution
        case refused
        case intercepted
        case unresponsive
        case dropped
        case rateLimited
        case serverError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch Tag(rawValue: raw) {
        case .noInternet: self = .noInternet
        case .nameResolution: self = .nameResolution
        case .refused: self = .refused
        case .intercepted: self = .intercepted
        case .unresponsive: self = .unresponsive
        case .dropped: self = .dropped
        case .rateLimited: self = .rateLimited
        case .serverError:
            self = try .serverError(status: container.decode(Int.self, forKey: .status))
        case nil:
            // Never throws. A newer peer naming an issue this build has not
            // heard of must not stop the frame decoding.
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noInternet: try container.encode(Tag.noInternet.rawValue, forKey: .type)
        case .nameResolution: try container.encode(Tag.nameResolution.rawValue, forKey: .type)
        case .refused: try container.encode(Tag.refused.rawValue, forKey: .type)
        case .intercepted: try container.encode(Tag.intercepted.rawValue, forKey: .type)
        case .unresponsive: try container.encode(Tag.unresponsive.rawValue, forKey: .type)
        case .dropped: try container.encode(Tag.dropped.rawValue, forKey: .type)
        case .rateLimited: try container.encode(Tag.rateLimited.rawValue, forKey: .type)
        case let .serverError(status):
            try container.encode(Tag.serverError.rawValue, forKey: .type)
            try container.encode(status, forKey: .status)
        case let .unknown(raw):
            try container.encode(raw, forKey: .type)
        }
    }
}
