import ChatKit
import Foundation
import GRDB

// MARK: - Conversation

/// The stored form of a `Conversation`.
///
/// A separate type rather than making the domain model itself a GRDB record:
/// `ChatKit` depends on nothing, and a `PersistableRecord` conformance there
/// would drag a database into the seam. The cost is this mapping; the benefit
/// is that the domain stays the domain.
struct ConversationRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversation"

    /// `lastActivity` and `lastReadAt` to the microsecond - see `StoredDate`.
    static func databaseDateEncodingStrategy(for _: String) -> DatabaseDateEncodingStrategy {
        StoredDate.encoding
    }

    static func databaseDateDecodingStrategy(for _: String) -> DatabaseDateDecodingStrategy {
        StoredDate.decoding
    }

    var id: String
    var kind: String
    var title: String?
    var avatarURL: String?
    var lastActivity: Date?
    var unreadCount: Int
    var hasUnread: Bool
    var isMuted: Bool
    var notificationLevel: String
    var isThreaded: Bool
    var memberCount: Int?
    var lastReadAt: Date?

    init(_ conversation: Conversation) throws {
        id = conversation.id.rawValue
        kind = try Wire.string(conversation.kind)
        title = conversation.title
        avatarURL = conversation.avatarURL?.absoluteString
        lastActivity = conversation.lastActivity
        unreadCount = conversation.unreadCount
        hasUnread = conversation.hasUnread
        isMuted = conversation.isMuted
        notificationLevel = try Wire.string(conversation.notificationLevel)
        isThreaded = conversation.isThreaded
        memberCount = conversation.memberCount
        lastReadAt = nil
    }

    func conversation(members: [Member.ID]) throws -> Conversation {
        try Conversation(
            id: Conversation.ID(id),
            kind: Wire.fromString(Conversation.Kind.self, kind),
            title: title,
            avatarURL: avatarURL.flatMap(URL.init(string:)),
            lastActivity: lastActivity,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            isMuted: isMuted,
            notificationLevel: Wire.fromString(NotificationLevel.self, notificationLevel),
            members: members,
            memberCount: memberCount,
            isThreaded: isThreaded
        )
    }
}

// MARK: - Member

struct MemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "member"

    var id: String
    var kind: String
    var displayName: String?
    var email: String?
    var avatarURL: String?
    var presence: String?

    init(_ member: Member) throws {
        id = member.id.rawValue
        kind = try Wire.string(member.kind)
        displayName = member.displayName
        email = member.email
        avatarURL = member.avatarURL?.absoluteString
        presence = try member.presence.map(Wire.string)
    }

    var member: Member {
        get throws {
            try Member(
                id: Member.ID(id),
                kind: Wire.fromString(Member.Kind.self, kind),
                displayName: displayName,
                email: email,
                avatarURL: avatarURL.flatMap(URL.init(string:)),
                // nil and .unknown mean different things: nobody has told us,
                // versus we were told something this build does not know.
                presence: presence.map { try Wire.fromString(Presence.self, $0) }
            )
        }
    }
}

struct MembershipRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversationMember"

    var conversationID: String
    var memberID: String
    var position: Int
}

// MARK: - Message

struct MessageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    /// `createdAt` and `editedAt` to the microsecond - see `StoredDate`. A
    /// mark-read position is taken from `createdAt` as read back from here.
    static func databaseDateEncodingStrategy(for _: String) -> DatabaseDateEncodingStrategy {
        StoredDate.encoding
    }

    static func databaseDateDecodingStrategy(for _: String) -> DatabaseDateDecodingStrategy {
        StoredDate.decoding
    }

    var id: String
    var conversationID: String
    var threadID: String
    var sender: String
    var text: String
    var createdAt: Date
    var editedAt: Date?
    var isDeleted: Bool
    var reactions: String
    var attachments: String
    var localID: String?
    var mentions: String

    init(_ message: Message) throws {
        id = message.id.rawValue
        conversationID = message.conversationID.rawValue
        threadID = message.threadID.rawValue
        sender = message.sender.rawValue
        text = message.text
        createdAt = message.createdAt
        editedAt = message.editedAt
        isDeleted = message.isDeleted
        reactions = try Wire.json(message.reactions)
        attachments = try Wire.json(message.attachments)
        localID = message.localID
        mentions = try Wire.json(message.mentions)
    }

    var message: Message {
        get throws {
            try Message(
                id: Message.ID(id),
                conversationID: Conversation.ID(conversationID),
                threadID: MessageThread.ID(threadID),
                sender: Member.ID(sender),
                text: text,
                createdAt: createdAt,
                editedAt: editedAt,
                isDeleted: isDeleted,
                reactions: Wire.value([Reaction].self, from: reactions),
                attachments: Wire.value([Attachment].self, from: attachments),
                localID: localID,
                mentions: Wire.value([Mention].self, from: mentions)
            )
        }
    }
}

// MARK: - Ephemeral

struct TypingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "typing"

    var conversationID: String
    var memberID: String
}

struct SyncStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncState"

    var id: Int
    var connectionState: String
    var lastError: String?
    var localMemberID: String?
}
