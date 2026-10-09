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
    /// **A cursor, so fetching and decoding stop at `limit`.** The store
    /// never deletes a message, so the candidates only grow; the list needs
    /// the newest `limit` of them and nothing older.
    ///
    /// A message whose conversation the store no longer lists is skipped
    /// (ruling 4). A reply's mention is read by its thread's position when
    /// the store has one (`readPosition(of:in:threads:)`). No `Date` is bound
    /// here (`StoredDate`'s rule).
    static func fetchMentionsOfMe(limit: Int, _ db: Database) throws -> [MentionOfMe] {
        guard let me = try fetchMe(db) else { return [] }
        let conversations = try Dictionary(
            uniqueKeysWithValues: fetchConversations(db).map { ($0.id, $0) }
        )
        let threadPositions = try fetchThreadReadPositions(db)
        let candidates = try MessageRow
            .filter(Column("mentions") != "[]" && Column("isDeleted") == false)
            .order(Column("createdAt").desc, Column("id").desc)
            .fetchCursor(db)
        var found: [MentionOfMe] = []
        while found.count < limit, let row = try candidates.next() {
            let message = try row.message
            guard message.mentionsMe(me), let conversation = conversations[message.conversationID] else {
                continue
            }
            let position = readPosition(of: message, in: conversation, threads: threadPositions)
            found.append(MentionOfMe(
                message: message, conversation: conversation,
                isUnread: MentionOfMe.isUnread(message, readPosition: position)
            ))
        }
        return found
    }

    /// A reply's mention is read by its thread's position when the store has
    /// one, else by its conversation's (threads spec §4.3): the conversation's
    /// position follows top-level messages and never covers a reply. A
    /// top-level message's is read by its conversation's.
    static func readPosition(
        of message: Message, in conversation: Conversation, threads: [ThreadKey: Date]
    ) -> Date? {
        guard message.isReply else { return conversation.readPosition }
        return threads[ThreadKey(conversation: message.conversationID, thread: message.threadID)]
            ?? conversation.readPosition
    }

    /// The badge: every unread mention, so it has no `limit` to stop at.
    ///
    /// **SQL narrows to the *unread* candidates before anything is decoded**,
    /// then `Message.mentionsMe` decides, so it stays the one definition.
    /// The narrowing is the list's own rules, restated:
    /// - the join drops a message whose conversation is gone (ruling 4);
    /// - `sender != me` is `mentionsMe`'s own first test, done early;
    /// - `COALESCE(the reply's thread position, the conversation's) IS NULL OR
    ///   createdAt > it` is `MentionOfMe.isUnread` over
    ///   `readPosition(of:in:threads:)`: the `LEFT JOIN` finds a thread row
    ///   for a reply only. Strictly after, because equality is read
    ///   (`findings.md` §42.2), and no position is unread.
    ///
    /// **Both sides of that `>` are `StoredDate` REAL seconds**, the same
    /// values the list decodes into the `Date`s its `>` compares, so the two
    /// agree to the microsecond. Nothing is bound but `me`, which is text.
    static func fetchUnreadMentionCount(_ db: Database) throws -> Int {
        guard let me = try fetchMe(db) else { return 0 }
        let candidates = try MessageRow.fetchCursor(
            db,
            sql: """
            SELECT message.* FROM message
            JOIN conversation ON conversation.id = message.conversationID
            LEFT JOIN thread ON message.isReply = 1
                AND thread.conversationID = message.conversationID AND thread.id = message.threadID
            WHERE message.mentions != '[]' AND message.isDeleted = 0 AND message.sender != ?
                AND (COALESCE(thread.readPosition, conversation.lastReadAt) IS NULL
                    OR message.createdAt > COALESCE(thread.readPosition, conversation.lastReadAt))
            """,
            arguments: [me.rawValue]
        )
        var count = 0
        while let row = try candidates.next() {
            if try row.message.mentionsMe(me) {
                count += 1
            }
        }
        return count
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
