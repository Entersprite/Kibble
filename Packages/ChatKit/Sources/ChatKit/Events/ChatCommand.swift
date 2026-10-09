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
    ///
    /// `attachments` are uploads, each returned by
    /// `ChatBackend.uploadAttachment(_:to:progress:)` for this conversation,
    /// and `text` may then be empty. Encoded only when there are some, and a
    /// missing key decodes to none, so a frame from before attachments
    /// existed means exactly what it meant then. A backend whose
    /// `Capabilities.canSendAttachments` is `false` refuses a send carrying
    /// any rather than posting the text alone.
    ///
    /// `mentions` are spans of `text` (UTF-16, `Mention`), encoded only when
    /// there are some, exactly like `attachments`. A backend whose
    /// `Capabilities.canMention` is `false` posts the text without them.
    case sendMessage(
        conversationID: Conversation.ID,
        threadID: MessageThread.ID?,
        text: String,
        localID: String?,
        attachments: [Attachment] = [],
        mentions: [Mention] = []
    )

    /// The person's own message, with new text and the mentions in it.
    ///
    /// `conversationID` and `threadID` address the message, for the reason
    /// `setReaction` gives: Google names a message by group, topic and id, and
    /// a backend holds no store. Optional on the wire, so a frame from before
    /// they existed decodes; a backend that needs them and is not given them
    /// refuses the command. `mentions` are spans of `text`, encoded only when
    /// there are some, as on `sendMessage` (edit spec §2).
    case editMessage(
        id: Message.ID,
        text: String,
        conversationID: Conversation.ID? = nil,
        threadID: MessageThread.ID? = nil,
        mentions: [Mention] = []
    )

    /// Addressed the way `editMessage` is, for the same reason.
    case deleteMessage(
        id: Message.ID,
        conversationID: Conversation.ID? = nil,
        threadID: MessageThread.ID? = nil
    )

    /// `add: false` removes the reaction. One command rather than two because
    /// the backend call is one call, and a client toggling a button should not
    /// have to know which direction it is going twice.
    ///
    /// `conversationID` and `threadID` address the message: Google's
    /// `update_reaction` names a message by group, topic and id, and a backend
    /// holds no store to look them up in. Optional on the wire, because a
    /// frame from before they existed must still decode; a backend that needs
    /// them and is not given them refuses the command. `customEmoji` is set for
    /// a workspace's custom emoji, and then `emoji` holds its `displayText`.
    case setReaction(
        messageID: Message.ID,
        emoji: String,
        add: Bool,
        conversationID: Conversation.ID? = nil,
        threadID: MessageThread.ID? = nil,
        customEmoji: CustomEmojiRef? = nil
    )

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

    /// "List this conversation's members." The answer arrives as
    /// `.membersChanged`. A backend that already knows them, or cannot list
    /// them, accepts it and does nothing (mention composer spec §3.1).
    case loadMembers(conversationID: Conversation.ID)

    /// Your own custom status: emoji, text and when it clears; `nil` clears it
    /// (set-your-status spec §2). A backend sends the Unicode emoji only, never
    /// a custom emoji's shortcode. The answer arrives as `.statusChanged` for you.
    case setStatus(MemberStatus?)

    /// Your own availability. The answer arrives as `.availabilityChanged`.
    case setAvailability(Availability)

    /// "This device is in use" (awake and unlocked) or not, so a backend can
    /// keep the person shown as active while it is (active-presence spec §2).
    /// A hint, like `watchPresence`: a backend that cannot honour it ignores it,
    /// so no capability gates it.
    case reportActivity(active: Bool)

    /// "This thread is read up to `upTo`", its newest message's own time; the
    /// backend owns any offset on the wire (threads spec §1). The outcome
    /// arrives as `.threadChanged` with `.read`.
    case markThreadRead(conversationID: Conversation.ID, threadID: MessageThread.ID, upTo: Date)

    /// Marks a thread unread from `at`, the message marked; `nil` clears the
    /// mark. The outcome arrives as `.threadChanged` with `.markedUnread`.
    case setThreadUnreadMark(conversationID: Conversation.ID, threadID: MessageThread.ID, at: Date?)

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
        case customEmoji
        case isTyping
        case upTo
        case level
        case members
        case attachments
        case mentions
        case status
        case availability
        case active
        case at
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
        case loadMembers
        case setStatus
        case setAvailability
        case reportActivity
        case markThreadRead
        case setThreadUnreadMark
        case unknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        let decoded =
            try Self.decodeMessageCommand(raw, from: container)
                ?? Self.decodeStateCommand(raw, from: container)
                ?? Self.decodeThreadCommand(raw, from: container)
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
                localID: container.decodeIfPresent(String.self, forKey: .localID),
                attachments: container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
                mentions: container.decodeIfPresent([Mention].self, forKey: .mentions) ?? []
            )
        case Tag.editMessage.rawValue:
            try .editMessage(
                id: container.decode(Message.ID.self, forKey: .id),
                text: container.decode(String.self, forKey: .text),
                conversationID: container.decodeIfPresent(Conversation.ID.self, forKey: .conversationID),
                threadID: container.decodeIfPresent(MessageThread.ID.self, forKey: .threadID),
                mentions: container.decodeIfPresent([Mention].self, forKey: .mentions) ?? []
            )
        case Tag.deleteMessage.rawValue:
            try .deleteMessage(
                id: container.decode(Message.ID.self, forKey: .id),
                conversationID: container.decodeIfPresent(Conversation.ID.self, forKey: .conversationID),
                threadID: container.decodeIfPresent(MessageThread.ID.self, forKey: .threadID)
            )
        case Tag.setReaction.rawValue:
            try .setReaction(
                messageID: container.decode(Message.ID.self, forKey: .messageID),
                emoji: container.decode(String.self, forKey: .emoji),
                add: container.decode(Bool.self, forKey: .add),
                conversationID: container.decodeIfPresent(Conversation.ID.self, forKey: .conversationID),
                threadID: container.decodeIfPresent(MessageThread.ID.self, forKey: .threadID),
                customEmoji: container.decodeIfPresent(CustomEmojiRef.self, forKey: .customEmoji)
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
        case Tag.loadMembers.rawValue:
            try .loadMembers(conversationID: container.decode(Conversation.ID.self, forKey: .conversationID))
        case Tag.setStatus.rawValue:
            try .setStatus(container.decodeIfPresent(MemberStatus.self, forKey: .status))
        case Tag.setAvailability.rawValue:
            try .setAvailability(container.decode(Availability.self, forKey: .availability))
        case Tag.reportActivity.rawValue:
            try .reportActivity(active: container.decode(Bool.self, forKey: .active))
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
            || encodeThreadCommand(into: &container)
        guard handled else {
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }

    private func encodeMessageCommand(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .sendMessage(conversationID, threadID, text, localID, attachments, mentions):
            try container.encode(Tag.sendMessage.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(localID, forKey: .localID)
            if !attachments.isEmpty {
                try container.encode(attachments, forKey: .attachments)
            }
            if !mentions.isEmpty {
                try container.encode(mentions, forKey: .mentions)
            }
        case let .editMessage(id, text, conversationID, threadID, mentions):
            try container.encode(Tag.editMessage.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            if !mentions.isEmpty {
                try container.encode(mentions, forKey: .mentions)
            }
        case let .deleteMessage(id, conversationID, threadID):
            try container.encode(Tag.deleteMessage.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
        case let .setReaction(messageID, emoji, add, conversationID, threadID, customEmoji):
            try container.encode(Tag.setReaction.rawValue, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(emoji, forKey: .emoji)
            try container.encode(add, forKey: .add)
            try container.encodeIfPresent(conversationID, forKey: .conversationID)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            try container.encodeIfPresent(customEmoji, forKey: .customEmoji)
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
        case let .loadMembers(conversationID):
            try container.encode(Tag.loadMembers.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
        case let .setStatus(status):
            try container.encode(Tag.setStatus.rawValue, forKey: .type)
            try container.encodeIfPresent(status, forKey: .status)
        case let .setAvailability(availability):
            try container.encode(Tag.setAvailability.rawValue, forKey: .type)
            try container.encode(availability, forKey: .availability)
        case let .reportActivity(active):
            try container.encode(Tag.reportActivity.rawValue, forKey: .type)
            try container.encode(active, forKey: .active)
        default:
            return false
        }
        return true
    }
}
