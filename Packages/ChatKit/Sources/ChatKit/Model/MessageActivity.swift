import Foundation

/// Structured conversation activity, never inferred from a message's text.
public enum MessageActivity: Codable, Hashable, Sendable {
    case pinnedMessage, pinnedResource
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try WireString.decode(from: decoder) {
        case "pinnedMessage": self = .pinnedMessage
        case "pinnedResource": self = .pinnedResource
        case let raw: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: String = switch self {
        case .pinnedMessage: "pinnedMessage"
        case .pinnedResource: "pinnedResource"
        case let .unknown(raw): raw
        }
        try WireString.encode(value, to: encoder)
    }
}
