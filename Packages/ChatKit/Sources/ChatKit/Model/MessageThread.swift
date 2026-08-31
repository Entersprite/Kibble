import Foundation

/// A thread — what the internal protocol calls a topic.
///
/// Named `MessageThread` rather than `Thread` because Foundation already has a
/// `Thread` and the collision would be silently resolved by whichever module
/// was imported last.
public struct MessageThread: Codable, Hashable, Sendable {
    public var id: ID
    public var conversationID: Conversation.ID

    /// Includes the message that started the thread, so a thread that has never
    /// been replied to has a count of one.
    public var replyCount: Int
    public var lastActivity: Date?

    public init(
        id: ID,
        conversationID: Conversation.ID,
        replyCount: Int = 0,
        lastActivity: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.replyCount = replyCount
        self.lastActivity = lastActivity
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
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
            replyCount: container.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0,
            lastActivity: container.decodeWireIfPresent(Date.self, forKey: .lastActivity)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(replyCount, forKey: .replyCount)
        try container.encodeWireIfPresent(lastActivity, forKey: .lastActivity)
    }
}
