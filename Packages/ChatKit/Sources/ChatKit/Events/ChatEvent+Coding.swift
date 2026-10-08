import Foundation

/// The wire format for `ChatEvent`. See the type itself for why none of this is
/// synthesised.
///
/// The decoder is a cascade of small functions and the encoder is a chain of
/// them, rather than one switch over fourteen cases each. That is a readability
/// tax paid for a reason: a single switch here trips the complexity limit this
/// repo lints with, and splitting it is preferable to raising the limit for
/// every other file. What it costs is the compiler's exhaustiveness check, and
/// `WireEncoding.unhandled` plus a test per case is what replaces that.
extension ChatEvent {
    enum CodingKeys: String, CodingKey {
        case type
        case state
        case conversations
        case conversation
        case message
        case id
        case conversationID
        case messageID
        case reactions
        case member
        case isTyping
        case lastReadAt
        case unread
        case members
        case presence
        case status
        case schedule
        case scope
        case reason
        case error
    }

    /// The discriminators, in one place, so the encoder and decoder cannot
    /// drift apart. The raw values are the case names.
    enum Tag: String {
        case connectionStateChanged
        case selfIdentified
        case conversationsChanged
        case conversationUpdated
        case messageReceived
        case messageUpdated
        case messageDeleted
        case reactionChanged
        case typingChanged
        case readStateChanged
        case membersChanged
        case membersResolved
        case presenceChanged
        case statusChanged
        case calendarChanged
        case gap
        case backendError
        case unknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        let decoded =
            try Self.decodeLifecycle(raw, from: container)
                ?? Self.decodeConversationEvent(raw, from: container)
                ?? Self.decodeMessageEvent(raw, from: container)
                ?? Self.decodeStateEvent(raw, from: container)
        self = try decoded ?? .unknown(type: raw, payload: UnknownFrame.payload(from: decoder))
    }

    private static func decodeLifecycle(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.connectionStateChanged.rawValue:
            try .connectionStateChanged(container.decode(ConnectionState.self, forKey: .state))
        case Tag.selfIdentified.rawValue:
            try .selfIdentified(container.decode(Member.self, forKey: .member))
        case Tag.gap.rawValue:
            try .gap(
                scope: container.decode(GapScope.self, forKey: .scope),
                reason: container.decode(String.self, forKey: .reason)
            )
        case Tag.backendError.rawValue:
            try .backendError(container.decode(ChatError.self, forKey: .error))
        default:
            nil
        }
    }

    private static func decodeConversationEvent(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.conversationsChanged.rawValue:
            try .conversationsChanged(container.decode([Conversation].self, forKey: .conversations))
        case Tag.conversationUpdated.rawValue:
            try .conversationUpdated(container.decode(Conversation.self, forKey: .conversation))
        case Tag.membersChanged.rawValue:
            try .membersChanged(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                members: container.decode([Member].self, forKey: .members)
            )
        case Tag.membersResolved.rawValue:
            try .membersResolved(container.decode([Member].self, forKey: .members))
        default:
            nil
        }
    }

    private static func decodeMessageEvent(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.messageReceived.rawValue:
            try .messageReceived(container.decode(Message.self, forKey: .message))
        case Tag.messageUpdated.rawValue:
            try .messageUpdated(container.decode(Message.self, forKey: .message))
        case Tag.messageDeleted.rawValue:
            try .messageDeleted(
                id: container.decode(Message.ID.self, forKey: .id),
                in: container.decode(Conversation.ID.self, forKey: .conversationID)
            )
        case Tag.reactionChanged.rawValue:
            try .reactionChanged(
                messageID: container.decode(Message.ID.self, forKey: .messageID),
                reactions: container.decode([Reaction].self, forKey: .reactions)
            )
        default:
            nil
        }
    }

    private static func decodeStateEvent(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatEvent? {
        switch tag {
        case Tag.typingChanged.rawValue:
            try .typingChanged(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                member: container.decode(Member.ID.self, forKey: .member),
                isTyping: container.decode(Bool.self, forKey: .isTyping)
            )
        case Tag.readStateChanged.rawValue:
            try .readStateChanged(
                conversationID: container.decode(
                    Conversation.ID.self, forKey: .conversationID
                ),
                lastReadAt: container.decodeWire(Date.self, forKey: .lastReadAt),
                unread: container.decode(Int.self, forKey: .unread)
            )
        case Tag.presenceChanged.rawValue:
            try .presenceChanged(
                member: container.decode(Member.ID.self, forKey: .member),
                presence: container.decode(Presence.self, forKey: .presence)
            )
        case Tag.statusChanged.rawValue:
            try .statusChanged(
                member: container.decode(Member.ID.self, forKey: .member),
                status: container.decodeIfPresent(MemberStatus.self, forKey: .status)
            )
        case Tag.calendarChanged.rawValue:
            try .calendarChanged(
                member: container.decode(Member.ID.self, forKey: .member),
                schedule: container.decodeIfPresent(CalendarSchedule.self, forKey: .schedule)
            )
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
        let handled = try encodeLifecycle(into: &container)
            || encodeConversationEvent(into: &container)
            || encodeMessageEvent(into: &container)
            || encodeStateEvent(into: &container)
        guard handled else {
            throw WireEncoding.unhandled(self, path: container.codingPath)
        }
    }

    private func encodeLifecycle(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .connectionStateChanged(state):
            try container.encode(Tag.connectionStateChanged.rawValue, forKey: .type)
            try container.encode(state, forKey: .state)
        case let .selfIdentified(member):
            try container.encode(Tag.selfIdentified.rawValue, forKey: .type)
            try container.encode(member, forKey: .member)
        case let .gap(scope, reason):
            try container.encode(Tag.gap.rawValue, forKey: .type)
            try container.encode(scope, forKey: .scope)
            try container.encode(reason, forKey: .reason)
        case let .backendError(error):
            try container.encode(Tag.backendError.rawValue, forKey: .type)
            try container.encode(error, forKey: .error)
        default:
            return false
        }
        return true
    }

    private func encodeConversationEvent(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .conversationsChanged(conversations):
            try container.encode(Tag.conversationsChanged.rawValue, forKey: .type)
            try container.encode(conversations, forKey: .conversations)
        case let .conversationUpdated(conversation):
            try container.encode(Tag.conversationUpdated.rawValue, forKey: .type)
            try container.encode(conversation, forKey: .conversation)
        case let .membersChanged(conversationID, members):
            try container.encode(Tag.membersChanged.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(members, forKey: .members)
        case let .membersResolved(members):
            try container.encode(Tag.membersResolved.rawValue, forKey: .type)
            try container.encode(members, forKey: .members)
        default:
            return false
        }
        return true
    }

    private func encodeMessageEvent(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .messageReceived(message):
            try container.encode(Tag.messageReceived.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .messageUpdated(message):
            try container.encode(Tag.messageUpdated.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        case let .messageDeleted(id, conversationID):
            try container.encode(Tag.messageDeleted.rawValue, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(conversationID, forKey: .conversationID)
        case let .reactionChanged(messageID, reactions):
            try container.encode(Tag.reactionChanged.rawValue, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(reactions, forKey: .reactions)
        default:
            return false
        }
        return true
    }

    private func encodeStateEvent(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .typingChanged(conversationID, member, isTyping):
            try container.encode(Tag.typingChanged.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(member, forKey: .member)
            try container.encode(isTyping, forKey: .isTyping)
        case let .readStateChanged(conversationID, lastReadAt, unread):
            try container.encode(Tag.readStateChanged.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encodeWire(lastReadAt, forKey: .lastReadAt)
            try container.encode(unread, forKey: .unread)
        case let .presenceChanged(member, presence):
            try container.encode(Tag.presenceChanged.rawValue, forKey: .type)
            try container.encode(member, forKey: .member)
            try container.encode(presence, forKey: .presence)
        case let .statusChanged(member, status):
            try container.encode(Tag.statusChanged.rawValue, forKey: .type)
            try container.encode(member, forKey: .member)
            try container.encodeIfPresent(status, forKey: .status)
        case let .calendarChanged(member, schedule):
            try container.encode(Tag.calendarChanged.rawValue, forKey: .type)
            try container.encode(member, forKey: .member)
            try container.encodeIfPresent(schedule, forKey: .schedule)
        default:
            return false
        }
        return true
    }
}
