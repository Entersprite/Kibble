import Foundation

/// One fact about a thread, as one event carries it (threads spec §1).
///
/// Narrow on purpose: each source knows one thing. History knows the counts
/// and the read position, a mute push knows whether you follow, a viewed push
/// knows how far you read. A store folds each into its `MessageThread`, so no
/// source has to claim what it does not know.
///
/// Open, like every enum on the wire: a fact from a newer backend decodes to
/// `.unknown` with its whole object kept, and re-encodes verbatim.
public enum ThreadChange: Codable, Hashable, Sendable {
    /// `messages` counts the thread's first message, as
    /// `MessageThread.replyCount` does. `unread` is the server's count of
    /// unread replies, `nil` when the source does not say.
    case counted(messages: Int, unread: Int?)

    /// The thread is read up to `upTo`. Equality is read.
    case read(upTo: Date)

    /// Marked unread from `at`; `nil` means the mark was cleared.
    case markedUnread(at: Date?)

    case followed(Bool)

    /// A fact from a newer backend, kept whole. `payload` is the entire
    /// object as it arrived, discriminator included.
    case unknown(type: String, payload: JSONValue)
}

// MARK: - Coding

public extension ThreadChange {
    internal enum CodingKeys: String, CodingKey {
        case type
        case messages
        case unread
        case upTo
        case at
        case followed
    }

    internal enum Tag: String {
        case counted
        case read
        case markedUnread
        case followed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch Tag(rawValue: raw) {
        case .counted:
            self = try .counted(
                messages: container.decode(Int.self, forKey: .messages),
                unread: container.decodeIfPresent(Int.self, forKey: .unread)
            )
        case .read:
            self = try .read(upTo: container.decodeWire(Date.self, forKey: .upTo))
        case .markedUnread:
            self = try .markedUnread(at: container.decodeWireIfPresent(Date.self, forKey: .at))
        case .followed:
            self = try .followed(container.decode(Bool.self, forKey: .followed))
        case nil:
            self = try .unknown(type: raw, payload: UnknownFrame.payload(from: decoder))
        }
    }

    /// `nil` is omitted, never written as `null`: a count nobody gave and a
    /// cleared mark both leave their key out.
    func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .counted(messages, unread):
            try container.encode(Tag.counted.rawValue, forKey: .type)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(unread, forKey: .unread)
        case let .read(upTo):
            try container.encode(Tag.read.rawValue, forKey: .type)
            try container.encodeWire(upTo, forKey: .upTo)
        case let .markedUnread(at):
            try container.encode(Tag.markedUnread.rawValue, forKey: .type)
            try container.encodeWireIfPresent(at, forKey: .at)
        case let .followed(followed):
            try container.encode(Tag.followed.rawValue, forKey: .type)
            try container.encode(followed, forKey: .followed)
        case .unknown:
            break
        }
    }
}
