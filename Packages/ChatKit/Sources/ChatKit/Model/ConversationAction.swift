import Foundation

/// An account's action on one conversation. Unknown actions remain decodable.
public enum ConversationAction: Hashable, Sendable, Codable {
    case markUnread, hide, block, leave, delete
    case unknown(String)

    public var wire: String {
        switch self {
        case .markUnread: "markUnread"
        case .hide: "hide"
        case .block: "block"
        case .leave: "leave"
        case .delete: "delete"
        case let .unknown(raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try WireString.decode(from: decoder)
        switch raw {
        case "markUnread": self = .markUnread
        case "hide": self = .hide
        case "block": self = .block
        case "leave": self = .leave
        case "delete": self = .delete
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try WireString.encode(wire, to: encoder)
    }

    public func isAvailable(for kind: Conversation.Kind) -> Bool {
        switch kind {
        case .directMessage, .appDirectMessage: self != .leave && !isUnknown
        case .space, .groupDirectMessage: self != .delete && !isUnknown
        default: false
        }
    }

    private var isUnknown: Bool {
        if case .unknown = self {
            return true
        }
        return false
    }
}
