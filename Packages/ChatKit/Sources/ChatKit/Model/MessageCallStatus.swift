import Foundation

/// Call activity in a conversation's history, separate from ordinary chat text
/// and from the live call controller that owns answering and ringing.
public enum MessageCallStatus: Codable, Hashable, Sendable {
    case started, missed, ended
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        switch try WireString.decode(from: decoder) {
        case "started": self = .started
        case "missed": self = .missed
        case "ended": self = .ended
        case let raw: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: String = switch self {
        case .started: "started"
        case .missed: "missed"
        case .ended: "ended"
        case let .unknown(raw): raw
        }
        try WireString.encode(value, to: encoder)
    }
}
