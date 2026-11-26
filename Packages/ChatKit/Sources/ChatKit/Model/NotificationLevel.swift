import Foundation

/// The provider's conversation notification level. With replies enabled,
/// `lessWithNewThreads` includes top-level messages and followed threads.
/// `less` includes mentions and followed threads. Mute is independent of this
/// level and is represented by `Conversation.isMuted`.
public enum NotificationLevel: Codable, Hashable, Sendable {
    case always
    case lessWithNewThreads
    case less
    case never
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "always": self = .always
        case "lessWithNewThreads": self = .lessWithNewThreads
        case "less": self = .less
        case "never": self = .never
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .always: "always"
        case .lessWithNewThreads: "lessWithNewThreads"
        case .less: "less"
        case .never: "never"
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
