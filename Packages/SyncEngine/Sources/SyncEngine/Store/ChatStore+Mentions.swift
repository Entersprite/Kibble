import ChatKit
import Foundation
import GRDB

/// One message that mentions the local user, with the conversation it is in
/// (the mentions-list spec §3).
public struct MentionOfMe: Sendable, Equatable, Identifiable {
    public var message: Message
    public var conversation: Conversation
    public var isUnread: Bool

    public var id: Message.ID {
        message.id
    }

    public init(message: Message, conversation: Conversation, isUnread: Bool) {
        self.message = message
        self.conversation = conversation
        self.isUnread = isUnread
    }

    /// Strictly after the read position, because equality is read
    /// (`findings.md` §42.2). No position means nobody has said, and that
    /// counts as unread.
    public static func isUnread(_ message: Message, readPosition: Date?) -> Bool {
        guard let readPosition else { return true }
        return message.createdAt > readPosition
    }
}

public extension ChatStore {
    /// Messages that mention the local user by name or through `@all`,
    /// not sent by them, not deleted, newest first, at most `limit`.
    func mentionsOfMe(limit: Int = 200) throws -> [MentionOfMe] {
        try database.read { db in try Self.fetchMentionsOfMe(limit: limit, db) }
    }

    /// Every unread mention, not only the `limit` the list shows: the row's badge.
    func unreadMentionCount() throws -> Int {
        try database.read(Self.fetchUnreadMentionCount)
    }

    func observeMentionsOfMe(limit: Int = 200) -> AsyncValueObservation<[MentionOfMe]> {
        ValueObservation
            .tracking { db in try Self.fetchMentionsOfMe(limit: limit, db) }
            .values(in: database)
    }

    func observeUnreadMentionCount() -> AsyncValueObservation<Int> {
        ValueObservation.tracking(Self.fetchUnreadMentionCount).values(in: database)
    }

    func mentionBackfill() throws -> MentionBackfillStatus {
        try database.read(Self.fetchMentionBackfill)
    }

    /// For the Mentions pane's "Looking for mentions…" and its footer.
    func observeMentionBackfill() -> AsyncValueObservation<MentionBackfillStatus> {
        ValueObservation.tracking(Self.fetchMentionBackfill).values(in: database)
    }
}

extension ChatStore {
    /// **Filtered in Swift, through `Message.mentionsMe`**, the one
    /// definition notifications also use. `mentions` is a JSON column, so
    /// SQL narrows only to the candidates: messages with any mention that
    /// are not deleted.
    ///
    /// **`me` is read here, from `syncState`, never passed in (ruling 3).**
    /// That puts it in the tracked region, so an observation started before
    /// the account was identified re-runs when it is.
    ///
    /// A message whose conversation the store no longer lists is skipped
    /// (ruling 4). No `Date` is bound here (`StoredDate`'s rule).
    static func fetchMentionsOfMe(limit: Int, _ db: Database) throws -> [MentionOfMe] {
        guard let me = try fetchMe(db) else { return [] }
        let conversations = try Dictionary(
            uniqueKeysWithValues: fetchConversations(db).map { ($0.id, $0) }
        )
        let candidates = try MessageRow
            .filter(Column("mentions") != "[]" && Column("isDeleted") == false)
            .order(Column("createdAt").desc, Column("id").desc)
            .fetchAll(db)
        var found: [MentionOfMe] = []
        for row in candidates where found.count < limit {
            let message = try row.message
            guard message.mentionsMe(me), let conversation = conversations[message.conversationID] else {
                continue
            }
            found.append(MentionOfMe(
                message: message, conversation: conversation,
                isUnread: MentionOfMe.isUnread(message, readPosition: conversation.readPosition)
            ))
        }
        return found
    }

    static func fetchUnreadMentionCount(_ db: Database) throws -> Int {
        try fetchMentionsOfMe(limit: .max, db).count(where: \.isUnread)
    }

    static func fetchMentionBackfill(_ db: Database) throws -> MentionBackfillStatus {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT mentionBackfillRunning, mentionBackfillFailed FROM syncState WHERE id = 1"
        ) else { return MentionBackfillStatus() }
        return MentionBackfillStatus(
            running: row["mentionBackfillRunning"], failedConversations: row["mentionBackfillFailed"]
        )
    }
}
