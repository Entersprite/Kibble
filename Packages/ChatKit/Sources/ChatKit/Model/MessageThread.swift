import Foundation

/// A thread — what the internal protocol calls a topic.
///
/// Named `MessageThread` rather than `Thread` because Foundation already has a
/// `Thread` and the collision would be silently resolved by whichever module
/// was imported last.
///
/// **The read shape a view takes** (threads spec §1): how many messages and
/// how recent, and what is known about following and reading it. A backend
/// says each fact through `ChatEvent.threadChanged`, and a store folds them
/// into this. Every field added for threads decodes to "nobody has said" when
/// its key is missing and is left out when it says nothing, so a frame from
/// before threads means what it meant then.
public struct MessageThread: Codable, Hashable, Sendable {
    public var id: ID
    public var conversationID: Conversation.ID

    /// Includes the message that started the thread, so a thread that has never
    /// been replied to has a count of one.
    public var replyCount: Int
    public var lastActivity: Date?

    /// Whether you follow it. `nil` is "nobody has said", never "no": a client
    /// then falls back on whether you took part (threads spec §4.2).
    public var isFollowed: Bool?

    /// How far you have read it, as the server says, or `nil` when nobody has
    /// said. Equality is read, as for a conversation (`findings.md` §42.2).
    public var readPosition: Date?

    /// The message you marked unread from ("Mark as Unread"), or `nil` for no
    /// mark.
    public var markedUnreadAt: Date?

    /// Unread replies as the server counts them, or `nil` when it has not
    /// said. Never derived on this side of the seam.
    public var unreadCount: Int?

    /// Up to three people who replied most recently, newest first, for the
    /// avatars on the thread's mark. Empty when nobody has replied.
    public var recentRepliers: [Member.ID]

    /// Whether the thread is unread by the client's own rule over the fields
    /// above (threads spec §4.2). Filled by a store's read, never by a backend.
    public var hasUnread: Bool

    public init(
        id: ID,
        conversationID: Conversation.ID,
        replyCount: Int = 0,
        lastActivity: Date? = nil,
        isFollowed: Bool? = nil,
        readPosition: Date? = nil,
        markedUnreadAt: Date? = nil,
        unreadCount: Int? = nil,
        recentRepliers: [Member.ID] = [],
        hasUnread: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.replyCount = replyCount
        self.lastActivity = lastActivity
        self.isFollowed = isFollowed
        self.readPosition = readPosition
        self.markedUnreadAt = markedUnreadAt
        self.unreadCount = unreadCount
        self.recentRepliers = recentRepliers
        self.hasUnread = hasUnread
    }
}

// MARK: - Identifier

public extension MessageThread {
    /// A thread identifier. Opaque, for the same reason `Message.ID` is: the
    /// protocol's `TopicId` is a pair of `{group_id, topic_id}`, so a bare topic
    /// id is not addressable on its own.
    struct ID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String {
            rawValue
        }

        public init(from decoder: any Decoder) throws {
            try self.init(WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(rawValue, to: encoder)
        }
    }
}

// MARK: - Coding

public extension MessageThread {
    internal enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case replyCount
        case lastActivity
        case isFollowed
        case readPosition
        case markedUnreadAt
        case unreadCount
        case recentRepliers
        case hasUnread
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
            replyCount: container.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0,
            lastActivity: container.decodeWireIfPresent(Date.self, forKey: .lastActivity),
            isFollowed: container.decodeIfPresent(Bool.self, forKey: .isFollowed),
            readPosition: container.decodeWireIfPresent(Date.self, forKey: .readPosition),
            markedUnreadAt: container.decodeWireIfPresent(Date.self, forKey: .markedUnreadAt),
            unreadCount: container.decodeIfPresent(Int.self, forKey: .unreadCount),
            recentRepliers: container.decodeIfPresent([Member.ID].self, forKey: .recentRepliers) ?? [],
            hasUnread: container.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false
        )
    }

    /// Writes only what says something: an absent optional, no repliers and
    /// `hasUnread == false` are left out, so `thread.json`, recorded before
    /// any of them existed, stays byte-identical. `isFollowed == false` is
    /// written: it is an answer, where `nil` is none.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(replyCount, forKey: .replyCount)
        try container.encodeWireIfPresent(lastActivity, forKey: .lastActivity)
        try container.encodeIfPresent(isFollowed, forKey: .isFollowed)
        try container.encodeWireIfPresent(readPosition, forKey: .readPosition)
        try container.encodeWireIfPresent(markedUnreadAt, forKey: .markedUnreadAt)
        try container.encodeIfPresent(unreadCount, forKey: .unreadCount)
        if !recentRepliers.isEmpty {
            try container.encode(recentRepliers, forKey: .recentRepliers)
        }
        if hasUnread {
            try container.encode(hasUnread, forKey: .hasUnread)
        }
    }
}
