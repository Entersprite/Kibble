import Foundation

/// A mention inside a message's text: who (or what) it names, and the span of
/// `text` it covers (spec §1).
public struct Mention: Codable, Hashable, Sendable {
    public var target: Target

    /// The span as the wire gives it - UTF-16 code units, measured
    /// (`findings.md` §41.1); a client must still check a span before drawing
    /// it (`MentionHighlight` does).
    public var start: Int

    /// See `start`.
    public var length: Int

    /// How the mention treats someone outside the conversation. Almost always
    /// `.mention`, which is never written to the wire.
    public var mode: Mode

    public init(target: Target, start: Int, length: Int, mode: Mode = .mention) {
        self.target = target
        self.start = start
        self.length = length
        self.mode = mode
    }
}

// MARK: - Mode

public extension Mention {
    /// How the mention treats someone outside the conversation (mention
    /// non-members spec §1): `.invite` adds them (wire type 1), `.withoutAdding`
    /// names them without adding (wire type 6). A plain string on the wire,
    /// like `NotificationLevel`; `.mention` is never written.
    enum Mode: Hashable, Sendable, Codable {
        case mention
        case invite
        case withoutAdding
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = switch raw {
            case "mention": .mention
            case "invite": .invite
            case "withoutAdding": .withoutAdding
            default: .unknown(raw)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var rawValue: String {
            switch self {
            case .mention: "mention"
            case .invite: "invite"
            case .withoutAdding: "withoutAdding"
            case let .unknown(raw): raw
            }
        }
    }
}

// MARK: - Target

public extension Mention {
    /// Who a mention names. `{"type": …}` discriminated, hand-coded, and an
    /// unknown type is kept verbatim — the same contract as `SettingsScope`.
    enum Target: Codable, Hashable, Sendable {
        case user(Member.ID)
        case all
        case unknown(type: String, payload: JSONValue)
    }
}

// MARK: - Mention coding

public extension Mention {
    internal enum CodingKeys: String, CodingKey {
        case target, start, length, mode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(Target.self, forKey: .target),
            start: container.decode(Int.self, forKey: .start),
            length: container.decode(Int.self, forKey: .length),
            mode: container.decodeIfPresent(Mode.self, forKey: .mode) ?? .mention
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(start, forKey: .start)
        try container.encode(length, forKey: .length)
        if mode != .mention {
            try container.encode(mode, forKey: .mode)
        }
    }
}

// MARK: - Target coding

public extension Mention.Target {
    private enum CodingKeys: String, CodingKey {
        case type, id
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "user": self = try .user(container.decode(Member.ID.self, forKey: .id))
        case "all": self = .all
        default: self = try .unknown(type: type, payload: UnknownFrame.payload(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .user(id):
            try container.encode("user", forKey: .type)
            try container.encode(id, forKey: .id)
        case .all:
            try container.encode("all", forKey: .type)
        case .unknown:
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }
}

// MARK: - Message.mentionsMe

public extension Message {
    /// Whether this message mentions `me`, by name or through `@all`
    /// (spec §2). Never your own message, and never for an unknown `me`.
    func mentionsMe(_ me: Member.ID?) -> Bool {
        guard let me, sender != me else { return false }
        return mentions.contains { mention in
            switch mention.target {
            case let .user(id): id == me
            case .all: true
            case .unknown: false
            }
        }
    }
}
