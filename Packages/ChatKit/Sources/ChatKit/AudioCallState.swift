import Foundation

public enum AudioCallPhase: Codable, Hashable, Sendable {
    case incoming, connecting, ringing, connected, failed, ended
    /// Acknowledges the decline operation without claiming remote ringing stopped.
    case declined
    case unknown(String)

    public var isTerminal: Bool {
        switch self {
        case .failed, .ended, .declined, .unknown: true
        default: false
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try WireString.decode(from: decoder)
        switch raw {
        case "incoming": self = .incoming
        case "connecting": self = .connecting
        case "ringing": self = .ringing
        case "connected": self = .connected
        case "failed": self = .failed
        case "ended": self = .ended
        case "declined": self = .declined
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .incoming: "incoming"
        case .connecting: "connecting"
        case .ringing: "ringing"
        case .connected: "connected"
        case .failed: "failed"
        case .ended: "ended"
        case .declined: "declined"
        case let .unknown(value): value
        }
        try WireString.encode(raw, to: encoder)
    }
}

public enum AudioCallDirection: Codable, Hashable, Sendable {
    case incoming, outgoing
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let raw = try WireString.decode(from: decoder)
        switch raw {
        case "incoming": self = .incoming
        case "outgoing": self = .outgoing
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let raw: String = switch self {
        case .incoming: "incoming"
        case .outgoing: "outgoing"
        case let .unknown(value): value
        }
        try WireString.encode(raw, to: encoder)
    }
}

public enum AudioCallEvent: Codable, Hashable, Sendable {
    case recipientsChanged([AudioCallRecipient])
    /// Actual subscription readiness, including failures after startup returned.
    case listenerChanged(isListening: Bool)
    case snapshot(AudioCallSnapshot)
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case type, recipients, call, isListening
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch raw {
        case "recipientsChanged":
            self = try .recipientsChanged(container.decode([AudioCallRecipient].self, forKey: .recipients))
        case "snapshot":
            self = try .snapshot(container.decode(AudioCallSnapshot.self, forKey: .call))
        case "listenerChanged":
            self = try .listenerChanged(isListening: container.decode(Bool.self, forKey: .isListening))
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .recipientsChanged(recipients):
            try container.encode("recipientsChanged", forKey: .type)
            try container.encode(recipients, forKey: .recipients)
        case let .snapshot(call):
            try container.encode("snapshot", forKey: .type)
            try container.encode(call, forKey: .call)
        case let .listenerChanged(isListening):
            try container.encode("listenerChanged", forKey: .type)
            try container.encode(isListening, forKey: .isListening)
        case let .unknown(raw):
            try container.encode(raw, forKey: .type)
        }
    }
}
