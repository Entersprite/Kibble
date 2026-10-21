import Foundation

/// A confirmed terminal cause, independent of a provider's signaling vocabulary.
public enum AudioCallEndReason: Codable, Hashable, Sendable {
    case localEnded, remoteEnded, declined
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try WireString.decode(from: decoder) {
        case "localEnded": self = .localEnded
        case "remoteEnded": self = .remoteEnded
        case "declined": self = .declined
        case let raw: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .localEnded: "localEnded"
        case .remoteEnded: "remoteEnded"
        case .declined: "declined"
        case let .unknown(raw): raw
        }
        try WireString.encode(raw, to: encoder)
    }
}
