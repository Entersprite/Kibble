import Foundation

/// A mention inside a message's text: who (or what) it names, and the span of
/// `text` it covers (spec §1).
public struct Mention: Codable, Hashable, Sendable {
    public var target: Target

    /// The span as the wire gives it - UTF-16 code units `[Verify]` (spec §1);
    /// a client must check a span before drawing it (`MentionHighlight` does).
    public var start: Int

    /// See `start`.
    public var length: Int

    public init(target: Target, start: Int, length: Int) {
        self.target = target
        self.start = start
        self.length = length
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
        case target, start, length
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(Target.self, forKey: .target),
            start: container.decode(Int.self, forKey: .start),
            length: container.decode(Int.self, forKey: .length)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(start, forKey: .start)
        try container.encode(length, forKey: .length)
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
