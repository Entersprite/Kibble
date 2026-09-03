import Foundation

/// Where the backend's connection currently is.
public enum ConnectionState: Codable, Hashable, Sendable {
    /// Never connected, and not trying to.
    case idle
    case connecting
    case connected

    /// Retrying after a failure. `attempt` counts from 1 and exists so a
    /// client can say "attempt 4" rather than spinning silently.
    ///
    /// **This is the steady state during an outage**, not a brief blip.
    /// Nothing recoverable gives up any more (design §3.1), so a client that
    /// treated `.reconnecting` as transient and `.disconnected` as the real
    /// news has it backwards.
    ///
    /// `issue` is what the UI branches on; `detail` is a diagnostic phrase for
    /// humans - an error domain and code, a status number - and never a URL or
    /// any request content. Both are optional so a frame from a peer that
    /// predates them still decodes.
    case reconnecting(attempt: Int, issue: ConnectionIssue?, detail: String?)

    /// `reason` is for humans and logs, never for branching: it is whatever
    /// the backend had to say. `nil` means the disconnect was deliberate - the
    /// answer to `disconnect()`. `issue` is the branchable form, and is `nil`
    /// for a deliberate disconnect for the same reason `reason` is.
    case disconnected(reason: String?, issue: ConnectionIssue?)

    /// A state this build does not know.
    ///
    /// Added because this enum used to **throw** on an unrecognised
    /// discriminator, in documented violation of the rule every other enum in
    /// this module follows: "an unknown discriminator decodes to `.unknown`
    /// and never throws - without this, deploying a newer server bricks every
    /// older client." The old doc comment argued a state machine with an
    /// uninterpretable state is no better than a lost frame; the answer is
    /// that a *client* with an uninterpretable state can still degrade toward
    /// optimism.
    ///
    /// **Today**, that means only this: `ChatWindow` renders this case as
    /// "Connecting…" rather than alarming someone about a state nobody here
    /// understands. The raw `String` this case carries is captured and decoded
    /// but not yet shown anywhere - there is no detail line yet for it to go
    /// in. Surfacing it (spec §8) is a later task's wiring; this comment used
    /// to claim that wiring already existed, and it did not.
    case unknown(String)
}

extension ConnectionState {
    enum CodingKeys: String, CodingKey {
        case type
        case attempt
        case reason
        case issue
        case detail
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
            self = try .reconnecting(
                attempt: container.decode(Int.self, forKey: .attempt),
                // Absent means nil, not a failure: "assume less" is the rule
                // a missing key gets, the same one `Capabilities` follows.
                issue: container.decodeIfPresent(ConnectionIssue.self, forKey: .issue),
                detail: container.decodeIfPresent(String.self, forKey: .detail)
            )
        case .disconnected:
            self = try .disconnected(
                reason: container.decodeIfPresent(String.self, forKey: .reason),
                issue: container.decodeIfPresent(ConnectionIssue.self, forKey: .issue)
            )
        case nil:
            self = .unknown(raw)
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
        case let .reconnecting(attempt, issue, detail):
            try container.encode(Tag.reconnecting.rawValue, forKey: .type)
            try container.encode(attempt, forKey: .attempt)
            // encodeIfPresent, so a nil issue omits the key entirely and a
            // fixture's frames stay byte-identical - `DeterminismTests`
            // asserts that.
            try container.encodeIfPresent(issue, forKey: .issue)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .disconnected(reason, issue):
            try container.encode(Tag.disconnected.rawValue, forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
            try container.encodeIfPresent(issue, forKey: .issue)
        case let .unknown(raw):
            try container.encode(raw, forKey: .type)
        }
    }
}
