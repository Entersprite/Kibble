import Foundation

/// One message.
public struct Message: Codable, Hashable, Sendable {
    public var id: ID

    /// Denormalised on purpose: an event delivers one message, and a client
    /// needs to know where it goes without a lookup table.
    public var conversationID: Conversation.ID

    /// Never optional. Every message on the internal protocol has a parent
    /// topic — in a flat group the topic simply holds one message — so a
    /// message with no thread is not a state the protocol can be in.
    public var threadID: MessageThread.ID
    public var sender: Member.ID
    public var text: String
    public var createdAt: Date

    /// `nil` means never edited, which is not the same as "edited at the moment
    /// it was created".
    public var editedAt: Date?

    /// Tombstone. A deleted message keeps its place in the ordering because the
    /// protocol keeps sending it, and a client that dropped it would leave a
    /// hole in its paging.
    public var isDeleted: Bool
    public var reactions: [Reaction]
    public var attachments: [Attachment]

    /// The client-chosen id of the send that produced this message, echoed back
    /// by the backend.
    ///
    /// This is echo suppression: after `sendMessage` the client usually shows
    /// the message optimistically, and the backend then delivers the real one
    /// through the event stream. Matching on `localID` is how the client knows
    /// to replace its optimistic copy instead of showing the message twice.
    /// `nil` means "not one of ours", which is the case for every message from
    /// anyone else and for our own sends made from another device.
    public var localID: String?

    /// Who or what this message's `text` mentions, and where (spec §1).
    /// Empty for the overwhelming majority of messages.
    public var mentions: [Mention]

    /// Links in `text`, and previews of links outside it (links spec §3.1).
    /// Empty for most messages.
    public var links: [MessageLink]

    public init(
        id: ID,
        conversationID: Conversation.ID,
        threadID: MessageThread.ID,
        sender: Member.ID,
        text: String,
        createdAt: Date,
        editedAt: Date? = nil,
        isDeleted: Bool = false,
        reactions: [Reaction] = [],
        attachments: [Attachment] = [],
        localID: String? = nil,
        mentions: [Mention] = [],
        links: [MessageLink] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.threadID = threadID
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.isDeleted = isDeleted
        self.reactions = reactions
        self.attachments = attachments
        self.localID = localID
        self.mentions = mentions
        self.links = links
    }
}

// MARK: - Identifier

public extension Message {
    /// A message identifier — **opaque and composite**.
    ///
    /// The real wire identifier for a message is not one string but three:
    /// `{group_id, topic_id, message_id}`. On the internal protocol a
    /// `MessageId` holds a `MessageParentId` (which holds a `TopicId`, which
    /// holds a `GroupId`) plus the message's own id. A bare message id is
    /// therefore **not addressable**: on its own it cannot be edited, deleted,
    /// reacted to, or used as a paging anchor.
    ///
    /// So `rawValue` here is an encoding of that triple whose shape belongs
    /// entirely to the backend that produced it. It **must never be parsed,
    /// split, compared for ordering, or constructed outside a backend
    /// implementation.** Client code may do exactly two things with it: hold it,
    /// and hand it back. A client that starts reading it has quietly coupled
    /// itself to one backend's format, and will break on the next one.
    struct ID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// Deliberately the raw value: an opaque token is only ever printed for
        /// diagnostics, and hiding it would make those diagnostics useless.
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

public extension Message {
    internal enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case threadID
        case sender
        case text
        case createdAt
        case editedAt
        case isDeleted
        case reactions
        case attachments
        case localID
        case mentions
        case links
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
            threadID: container.decode(MessageThread.ID.self, forKey: .threadID),
            sender: container.decode(Member.ID.self, forKey: .sender),
            text: container.decodeIfPresent(String.self, forKey: .text) ?? "",
            createdAt: container.decodeWire(Date.self, forKey: .createdAt),
            editedAt: container.decodeWireIfPresent(Date.self, forKey: .editedAt),
            isDeleted: container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false,
            reactions: container.decodeIfPresent([Reaction].self, forKey: .reactions) ?? [],
            attachments: container.decodeIfPresent(
                [Attachment].self, forKey: .attachments
            ) ?? [],
            localID: container.decodeIfPresent(String.self, forKey: .localID),
            mentions: container.decodeIfPresent([Mention].self, forKey: .mentions) ?? [],
            links: container.decodeIfPresent([MessageLink].self, forKey: .links) ?? []
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(sender, forKey: .sender)
        try container.encode(text, forKey: .text)
        try container.encodeWire(createdAt, forKey: .createdAt)
        try container.encodeWireIfPresent(editedAt, forKey: .editedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encode(reactions, forKey: .reactions)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(localID, forKey: .localID)
        if !mentions.isEmpty {
            try container.encode(mentions, forKey: .mentions)
        }
        if !links.isEmpty {
            try container.encode(links, forKey: .links)
        }
    }
}
