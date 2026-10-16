import Foundation

/// Ephemeral composition in one exact context. A missing thread means the main conversation.
public struct TypingUpdate: Codable, Hashable, Sendable {
    public var conversationID: Conversation.ID
    public var threadID: MessageThread.ID?
    public var member: Member.ID
    public var isTyping: Bool
    /// Optional ordering token, comparable only for this member and context.
    public var version: Int64?

    public init(
        conversationID: Conversation.ID,
        threadID: MessageThread.ID? = nil,
        member: Member.ID,
        isTyping: Bool,
        version: Int64? = nil
    ) {
        self.conversationID = conversationID
        self.threadID = threadID
        self.member = member
        self.isTyping = isTyping
        self.version = version
    }
}

/// A read-through position, not the wall-clock time at which somebody viewed a message.
public struct ReadPosition: Codable, Hashable, Sendable {
    public var member: Member.ID
    public var readThrough: Date

    public init(member: Member.ID, readThrough: Date) {
        self.member = member
        self.readThrough = readThrough
    }

    private enum CodingKeys: String, CodingKey { case member, readThrough }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        member = try values.decode(Member.ID.self, forKey: .member)
        let raw = try values.decode(String.self, forKey: .readThrough)
        guard let date = ReadPositionDate.date(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .readThrough,
                in: values,
                debugDescription: "Invalid read position date"
            )
        }
        readThrough = date
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(member, forKey: .member)
        try values.encode(ReadPositionDate.string(readThrough), forKey: .readThrough)
    }
}

/// Per-reader upserts. Missing enabled preserves availability; explicit false clears receipts.
/// An absent reader is not a deletion. Only an explicit disable starts a new receipt epoch.
public struct ReadReceiptUpdate: Codable, Hashable, Sendable {
    public var conversationID: Conversation.ID
    public var enabled: Bool?
    public var positions: [ReadPosition]

    public init(conversationID: Conversation.ID, enabled: Bool? = nil, positions: [ReadPosition]) {
        self.conversationID = conversationID
        self.enabled = enabled
        self.positions = positions
    }
}

/// Values for the selected conversation; no provider identifiers or timers belong in views.
public struct ConversationActivity: Hashable, Sendable {
    public var typing: [TypingUpdate] = []
    public var receipts: [ReadPosition] = []
    public var receiptsEnabled: Bool?

    public init() {}
}
