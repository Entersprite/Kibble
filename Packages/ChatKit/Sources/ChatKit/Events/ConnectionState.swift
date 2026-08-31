import Foundation

/// Where the backend's connection currently is.
///
/// Note the asymmetry with the rest of this protocol: this enum has **no
/// `.unknown` case**, so an unrecognised discriminator throws rather than
/// degrading. That is a known sharp edge — see the note on `ChatEvent` — and
/// the reason it is tolerable today is that a state machine with an
/// uninterpretable state is not obviously better than a lost frame. If a
/// backend ever needs a fifth state, this enum needs an `.unknown(String)` case
/// and that is a wire-format change.
public enum ConnectionState: Codable, Hashable, Sendable {
    /// Never connected, and not trying to.
    case idle
    case connecting
    case connected

    /// Retrying after a failure. `attempt` counts from 1 and exists so a client
    /// can say "attempt 4" rather than spinning silently forever.
    case reconnecting(attempt: Int)

    /// `reason` is for humans and logs, never for branching: it is whatever the
    /// backend had to say. `nil` means the disconnect was deliberate — the
    /// answer to `disconnect()`.
    case disconnected(reason: String?)
}

extension ConnectionState {
    enum CodingKeys: String, CodingKey {
        case type
        case attempt
        case reason
    }

    enum Tag: String {
        case idle
        case connecting
        case connected
        case reconnecting
        case disconnected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch Tag(rawValue: raw) {
        case .idle:
            self = .idle
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reconnecting:
            self = try .reconnecting(attempt: container.decode(Int.self, forKey: .attempt))
        case .disconnected:
            self = try .disconnected(
                reason: container.decodeIfPresent(String.self, forKey: .reason)
            )
        case nil:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown ConnectionState type: \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Tag.idle.rawValue, forKey: .type)
        case .connecting:
            try container.encode(Tag.connecting.rawValue, forKey: .type)
        case .connected:
            try container.encode(Tag.connected.rawValue, forKey: .type)
        case let .reconnecting(attempt):
            try container.encode(Tag.reconnecting.rawValue, forKey: .type)
            try container.encode(attempt, forKey: .attempt)
        case let .disconnected(reason):
            try container.encode(Tag.disconnected.rawValue, forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}
