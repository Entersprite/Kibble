import Foundation

/// How much a `ChatEvent.gap` invalidates.
///
/// Like `ConnectionState`, closed: an unrecognised discriminator throws. A
/// third scope is unlikely — a gap is either local to one conversation or it is
/// not — but see the note on `ChatEvent`.
public enum GapScope: Codable, Hashable, Sendable {
    /// Everything the client believes is suspect. The only correct response is
    /// to reload conversations and re-fetch whatever is on screen.
    case everything

    /// One conversation's messages are suspect; the rest of the client's state
    /// stands.
    case conversation(Conversation.ID)
}

extension GapScope {
    enum CodingKeys: String, CodingKey {
        case type
        case conversationID
    }

    enum Tag: String {
        case everything
        case conversation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch Tag(rawValue: raw) {
        case .everything:
            self = .everything
        case .conversation:
            self = try .conversation(
                container.decode(Conversation.ID.self, forKey: .conversationID)
            )
        case nil:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unknown GapScope type: \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everything:
            try container.encode(Tag.everything.rawValue, forKey: .type)
        case let .conversation(id):
            try container.encode(Tag.conversation.rawValue, forKey: .type)
            try container.encode(id, forKey: .conversationID)
        }
    }
}
