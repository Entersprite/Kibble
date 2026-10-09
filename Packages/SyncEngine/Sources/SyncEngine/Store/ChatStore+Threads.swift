import ChatKit
import Foundation
import GRDB

/// A followed thread, for the Threads list (threads spec §5.3): its first
/// message and its summary.
public struct FollowedThread: Sendable, Equatable {
    public var root: Message
    public var thread: MessageThread

    public init(root: Message, thread: MessageThread) {
        self.root = root
        self.thread = thread
    }
}

/// One thread's address. A topic id is unique only inside its conversation,
/// which is why the `thread` table is keyed by the pair. Also the model's key
/// for its per-thread bookkeeping (Task 8), hence `Sendable`.
struct ThreadKey: Hashable, Sendable {
    var conversation: Conversation.ID
    var thread: MessageThread.ID
}

// MARK: - Reading

public extension ChatStore {
    /// One thread's messages, its first message included, oldest first: the
    /// panel (threads spec §4.1). A reply stored before v13 is here too.
    func threadMessages(_ thread: MessageThread.ID, in conversation: Conversation.ID) throws -> [Message] {
        try database.read { db in try Self.fetchThreadMessages(thread, conversation, db) }
    }

    func observeThread(
        _ thread: MessageThread.ID, in conversation: Conversation.ID
    ) -> AsyncValueObservation<[Message]> {
        ValueObservation
            .tracking { db in try Self.fetchThreadMessages(thread, conversation, db) }
            .values(in: database)
    }

    /// Every thread of one conversation that has a stored reply or a `thread`
    /// row, keyed by id, in one read. The transcript's marks come from this,
    /// observed once per open conversation, never read per bubble (CLAUDE.md,
    /// session 46).
    func threadSummaries(in conversation: Conversation.ID) throws -> [MessageThread.ID: MessageThread] {
        try database.read { db in try Self.fetchThreadSummaries(conversation, only: nil, db) }
    }

    func observeThreadSummaries(
        in conversation: Conversation.ID
    ) -> AsyncValueObservation<[MessageThread.ID: MessageThread]> {
        ValueObservation
            .tracking { db in try Self.fetchThreadSummaries(conversation, only: nil, db) }
            .values(in: database)
    }

    /// One summary, read now: exactly `threadSummaries(in:)[thread]`. For the
    /// notification coordinator, which decides one arrival at a time.
    func thread(_ thread: MessageThread.ID, in conversation: Conversation.ID) throws -> MessageThread? {
        try database.read { db in try Self.fetchThreadSummaries(conversation, only: thread, db)[thread] }
    }

    /// Threads the server says you follow (`isFollowed = 1`, never the
    /// fallback), with their first message stored and at least one reply
    /// (`replyCount > 1`), in a conversation the store still lists; newest
    /// activity first, at most `limit`.
    ///
    /// **A reply is required** because posting follows a topic and pushes 4
    /// and 9 carry no count (`findings.md` §63.10): without it, every
    /// single-message topic you posted would be listed.
    func followedThreads(limit: Int) throws -> [FollowedThread] {
        try database.read { db in try Self.fetchFollowedThreads(limit: limit, db) }
    }

    /// **Duplicates are dropped**, as `observeConversations` drops them: every
    /// write to `message` or `thread` re-runs this read, and most change no
    /// followed thread.
    func observeFollowedThreads(limit: Int) -> AsyncValueObservation<[FollowedThread]> {
        ValueObservation
            .tracking { db in try Self.fetchFollowedThreads(limit: limit, db) }
            .removeDuplicates()
            .values(in: database)
    }

    /// The Threads row's badge: every unread thread the list would show, not
    /// only the `limit` it shows.
    func unreadThreadCount() throws -> Int {
        try database.read(Self.fetchUnreadThreadCount)
    }

    /// Duplicates dropped, for `observeFollowedThreads(limit:)`'s reason.
    func observeUnreadThreadCount() -> AsyncValueObservation<Int> {
        ValueObservation.tracking(Self.fetchUnreadThreadCount).removeDuplicates().values(in: database)
    }
}

// MARK: - The queries

extension ChatStore {
    static func fetchThreadMessages(
        _ thread: MessageThread.ID, _ conversation: Conversation.ID, _ db: Database
    ) throws -> [Message] {
        try MessageRow
            .filter(Column("conversationID") == conversation.rawValue)
            .filter(Column("threadID") == thread.rawValue)
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
            .map { try $0.message }
    }

    /// Roots are each followed thread's oldest message that is not a reply.
    /// A thread whose summary counts no reply is dropped before the limit, so
    /// the badge (`fetchUnreadThreadCount`) drops it too.
    /// The summaries are one read for every followed thread at once
    /// (`fetchFollowedThreadSummaries`), never one per conversation or per
    /// thread. A conversation the store no longer lists is left out, as the
    /// Mentions list leaves it out.
    static func fetchFollowedThreads(limit: Int?, _ db: Database) throws -> [FollowedThread] {
        let listed = try Set(String.fetchAll(db, sql: "SELECT id FROM conversation"))
        let roots = try MessageRow.fetchAll(
            db,
            sql: """
            SELECT message.* FROM message
            JOIN thread ON thread.conversationID = message.conversationID AND thread.id = message.threadID
            WHERE thread.isFollowed = 1 AND message.isReply = 0
            ORDER BY message.createdAt ASC, message.id ASC
            """
        )
        var rootByKey: [ThreadKey: Message] = [:]
        for row in roots where listed.contains(row.conversationID) {
            let key = ThreadKey(
                conversation: Conversation.ID(row.conversationID), thread: MessageThread.ID(row.threadID)
            )
            if rootByKey[key] == nil {
                rootByKey[key] = try row.message
            }
        }
        let summaries = try fetchFollowedThreadSummaries(db)
        var items = rootByKey.compactMap { key, root -> FollowedThread? in
            // Only a thread with a reply, before the limit.
            guard let thread = summaries[key], thread.replyCount > 1 else { return nil }
            return FollowedThread(root: root, thread: thread)
        }
        items.sort(by: newestActivityFirst)
        return limit.map { Array(items.prefix($0)) } ?? items
    }

    static func fetchUnreadThreadCount(_ db: Database) throws -> Int {
        try fetchFollowedThreads(limit: nil, db).count(where: \.thread.hasUnread)
    }

    /// Every stored thread read position, for the Mentions reads: a mention in
    /// a reply is read by its thread's position when the store has one
    /// (threads spec §4.3).
    static func fetchThreadReadPositions(_ db: Database) throws -> [ThreadKey: Date] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT conversationID, id, readPosition FROM thread WHERE readPosition IS NOT NULL"
        )
        var positions: [ThreadKey: Date] = [:]
        for row in rows {
            let key = ThreadKey(
                conversation: Conversation.ID(row["conversationID"] as String),
                thread: MessageThread.ID(row["id"] as String)
            )
            positions[key] = StoredDate.date(row["readPosition"])
        }
        return positions
    }

    /// Newest activity first; a thread with none sorts last; ties by
    /// conversation and thread id, so the order is stable.
    private static func newestActivityFirst(_ lhs: FollowedThread, _ rhs: FollowedThread) -> Bool {
        let left = lhs.thread.lastActivity ?? .distantPast
        let right = rhs.thread.lastActivity ?? .distantPast
        if left != right {
            return left > right
        }
        return (lhs.thread.conversationID.rawValue, lhs.thread.id.rawValue)
            < (rhs.thread.conversationID.rawValue, rhs.thread.id.rawValue)
    }
}
