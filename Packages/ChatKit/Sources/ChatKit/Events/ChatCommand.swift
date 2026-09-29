import Foundation

/// Everything a client can ask a backend to do, as one value.
///
/// The other half of the protocol, and the mirror image of `ChatEvent`: a
/// bridge server reads these off the wire, a local backend gets the identical
/// values in process. Commands are fire-and-forget by design — `send` throws if
/// the command could not be *submitted*, and the result of the command arrives
/// as an event, because that is the only path a remote backend has anyway.
///
/// The coding rules are `ChatEvent`'s, exactly: an explicit `"type"`
/// discriminator, payload keys named after the argument labels, `nil` omitted
/// rather than written as `null`, and an unrecognised discriminator decoding to
/// `.unknown(type:payload:)` and re-encoding verbatim. That last one matters in
/// this direction too: a bridge server built before a client's newest feature
/// must be able to read the frame, recognise that it cannot honour it, and say
/// so — rather than fail to parse and drop the connection.
public enum ChatCommand: Codable, Hashable, Sendable {
    /// `threadID` is `nil` to start a new thread, which in a flat conversation
    /// is the only case there is.
    ///
    /// `localID` is chosen by the client and echoed back on the resulting
    /// `Message`, which is what lets the client replace its optimistic copy
    /// instead of showing the message twice. A client that does not show
    /// messages optimistically can leave it `nil`.
    case sendMessage(
        conversationID: Conversation.ID,
        threadID: MessageThread.ID?,
        text: String,
        localID: String?
    )

    case editMessage(id: Message.ID, text: String)
    case deleteMessage(id: Message.ID)

    /// `add: false` removes the reaction. One command rather than two because
    /// the backend call is one call, and a client toggling a button should not
    /// have to know which direction it is going twice.
    case setReaction(messageID: Message.ID, emoji: String, add: Bool)

    /// Typing state is a claim about *now*, so it has no timestamp and no
    /// delivery guarantee. A backend whose `Capabilities.canSendTypingState` is
    /// `false` will reject this.
    case setTyping(conversationID: Conversation.ID, threadID: MessageThread.ID?, isTyping: Bool)

    /// `upTo` is a timestamp rather than a message id because read state on the
    /// wire is a watermark, not a pointer to a message. It also means a client
    /// can mark a conversation read without knowing what the last message was.
    case markRead(conversationID: Conversation.ID, upTo: Date)

    case setNotificationLevel(conversationID: Conversation.ID, level: NotificationLevel)

    /// "These people are on screen; tell me their presence." A hint, not a
    /// request: the answer, if any, arrives as `.presenceChanged`, and a
    /// backend that cannot honour it may ignore it. It says nothing about the
    /// local user, so it reveals nothing ghost mode would withhold.
    ///
    /// It exists because a backend cannot see what a client has stored. A
    /// transcript shows every message kept from earlier launches, while a
    /// backend only learns of the senders on pages it fetched this session.
    case watchPresence(members: [Member.ID])

    /// A command from a newer client, kept whole so that a backend can report
    /// precisely what it was asked and could not do.
    case unknown(type: String, payload: JSONValue)
}

// MARK: - Coding

extension ChatCommand {
    enum CodingKeys: String, CodingKey {
        case type
        case conversationID
        case threadID
        case text
        case localID
        case id
        case messageID
        case emoji
        case add
        case isTyping
        case upTo
        case level
        case members
    }

    enum Tag: String {
        case sendMessage
        case editMessage
        case deleteMessage
        case setReaction
        case setTyping
        case markRead
        case setNotificationLevel
        case watchPresence
        case unknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        let decoded =
            try Self.decodeMessageCommand(raw, from: container)
                ?? Self.decodeStateCommand(raw, from: container)
        self = try decoded ?? .unknown(type: raw, payload: UnknownFrame.payload(from: decoder))
    }

    private static func decodeMessageCommand(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatCommand? {
        switch tag {
        case Tag.sendMessage.rawValue:
            try .sendMessage(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                threadID: container.decodeIfPresent(
                    MessageThread.ID.self, forKey: .threadID
                ),
                text: container.decode(String.self, forKey: .text),
                localID: container.decodeIfPresent(String.self, forKey: .localID)
            )
        case Tag.editMessage.rawValue:
            try .editMessage(
                id: container.decode(Message.ID.self, forKey: .id),
                text: container.decode(String.self, forKey: .text)
            )
        case Tag.deleteMessage.rawValue:
            try .deleteMessage(id: container.decode(Message.ID.self, forKey: .id))
        case Tag.setReaction.rawValue:
            try .setReaction(
                messageID: container.decode(Message.ID.self, forKey: .messageID),
                emoji: container.decode(String.self, forKey: .emoji),
                add: container.decode(Bool.self, forKey: .add)
            )
        default:
            nil
        }
    }

    private static func decodeStateCommand(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatCommand? {
        switch tag {
        case Tag.setTyping.rawValue:
            try .setTyping(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                threadID: container.decodeIfPresent(
                    MessageThread.ID.self, forKey: .threadID
                ),
                isTyping: container.decode(Bool.self, forKey: .isTyping)
            )
        case Tag.markRead.rawValue:
            try .markRead(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                upTo: container.decodeWire(Date.self, forKey: .upTo)
            )
        case Tag.setNotificationLevel.rawValue:
            try .setNotificationLevel(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                level: container.decode(NotificationLevel.self, forKey: .level)
            )
        case Tag.watchPresence.rawValue:
            try .watchPresence(members: container.decode([Member.ID].self, forKey: .members))
        default:
            nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(type, payload) = self {
            try UnknownFrame.encode(type: type, payload: payload, to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        let handled = try encodeMessageCommand(into: &container)
            || encodeStateCommand(into: &container)
        guard handled else {
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }

    private func encodeMessageCommand(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .sendMessage(conversationID, threadID, text, localID):
            try container.encode(Tag.sendMessage.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(localID, forKey: .localID)
        case let .editMessage(id, text):
            try container.encode(Tag.editMessage.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case let .deleteMessage(id):
            try container.encode(Tag.deleteMessage.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
        case let .setReaction(messageID, emoji, add):
            try container.encode(Tag.setReaction.rawValue, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(emoji, forKey: .emoji)
            try container.encode(add, forKey: .add)
        default:
            return false
        }
        return true
    }

    private func encodeStateCommand(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .setTyping(conversationID, threadID, isTyping):
            try container.encode(Tag.setTyping.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            try container.encode(isTyping, forKey: .isTyping)
        case let .markRead(conversationID, upTo):
            try container.encode(Tag.markRead.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encodeWire(upTo, forKey: .upTo)
        case let .setNotificationLevel(conversationID, level):
            try container.encode(Tag.setNotificationLevel.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(level, forKey: .level)
        case let .watchPresence(members):
            try container.encode(Tag.watchPresence.rawValue, forKey: .type)
            try container.encode(members, forKey: .members)
        default:
            return false
        }
        return true
    }
}
