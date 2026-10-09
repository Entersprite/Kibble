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
    /// fallback), with their first message stored, in a conversation the
    /// store still lists; newest activity first, at most `limit`.
    func followedThreads(limit: Int) throws -> [FollowedThread] {
        try database.read { db in try Self.fetchFollowedThreads(limit: limit, db) }
    }

    func observeFollowedThreads(limit: Int) -> AsyncValueObservation<[FollowedThread]> {
        ValueObservation
            .tracking { db in try Self.fetchFollowedThreads(limit: limit, db) }
            .values(in: database)
    }

    /// The Threads row's badge: every unread thread the list would show, not
    /// only the `limit` it shows.
    func unreadThreadCount() throws -> Int {
        try database.read(Self.fetchUnreadThreadCount)
    }

    func observeUnreadThreadCount() -> AsyncValueObservation<Int> {
        ValueObservation.tracking(Self.fetchUnreadThreadCount).values(in: database)
    }
}

// MARK: - The queries

extension ChatStore {
    /// How many repliers a summary names: the mark draws three avatars.
    static let recentReplierLimit = 3

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

    /// The summaries of one conversation's threads, or of one thread with
    /// `only`. **Three queries for the whole conversation, never one per
    /// thread**: the stored messages' counts and times, the `thread` rows, and
    /// the recent repliers.
    ///
    /// `me` is read here, as `fetchMentionsOfMe` reads it, so an observation
    /// started before the account was identified re-runs when it is.
    static func fetchThreadSummaries(
        _ conversation: Conversation.ID, only thread: MessageThread.ID?, _ db: Database
    ) throws -> [MessageThread.ID: MessageThread] {
        let scope = ThreadScope(conversation: conversation, thread: thread)
        let stats = try fetchThreadStats(scope, me: fetchMe(db), db)
        let states = try fetchThreadStates(scope, db)
        let repliers = try fetchRecentRepliers(scope, db)
        var summaries: [MessageThread.ID: MessageThread] = [:]
        for id in Set(stats.filter(\.value.hasReply).keys).union(states.keys) {
            summaries[id] = summary(
                of: ThreadKey(conversation: conversation, thread: id),
                stats: stats[id] ?? ThreadStats(), state: states[id] ?? ThreadState(),
                repliers: repliers[id] ?? []
            )
        }
        return summaries
    }

    /// Roots are each followed thread's oldest message that is not a reply.
    /// Summaries are read once per conversation that has one, never once per
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
        var items: [FollowedThread] = []
        for conversation in Set(rootByKey.keys.map(\.conversation)) {
            let summaries = try fetchThreadSummaries(conversation, only: nil, db)
            items += summaries.compactMap { id, summary in
                rootByKey[ThreadKey(conversation: conversation, thread: id)].map {
                    FollowedThread(root: $0, thread: summary)
                }
            }
        }
        items.sort(by: newestActivityFirst)
        return limit.map { Array(items.prefix($0)) } ?? items
    }

    static func fetchUnreadThreadCount(_ db: Database) throws -> Int {
        try fetchFollowedThreads(limit: nil, db).count(where: \.thread.hasUnread)
    }

    /// Conversations with a stored thread that is unread: the half of
    /// `Conversation.hasUnreadThread` the store derives (threads spec §4.2,
    /// "any of its stored threads is unread"). **`ThreadUnreadRule` decides,
    /// the fallback included**, through the same summaries the marks read, so
    /// the sidebar and the Threads badge cannot disagree about a thread.
    ///
    /// SQL only narrows to the conversations where the rule could answer yes,
    /// and is deliberately looser than it: a thread marked or counted unread,
    /// or one with a read position, no count and any reply at or after that
    /// position, from anyone, deleted or not. A conversation with no such
    /// thread costs no summary read; one with only threads the rule calls read
    /// is read and left out.
    static func fetchConversationsWithUnreadThreads(_ db: Database) throws -> Set<Conversation.ID> {
        let candidates = try String.fetchAll(
            db,
            sql: """
            SELECT DISTINCT thread.conversationID FROM thread
            WHERE thread.markedUnreadAt IS NOT NULL OR thread.unreadCount > 0
                OR (thread.unreadCount IS NULL AND thread.readPosition IS NOT NULL AND EXISTS (
                    SELECT 1 FROM message
                    WHERE message.conversationID = thread.conversationID AND message.threadID = thread.id
                        AND message.isReply = 1 AND message.createdAt >= thread.readPosition
                ))
            """
        )
        return try Set(candidates.map { Conversation.ID($0) }.filter { conversation in
            try fetchThreadSummaries(conversation, only: nil, db).values.contains(where: \.hasUnread)
        })
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

// MARK: - A summary's parts

/// Which messages and rows a summary read covers: one conversation, or one
/// thread of it.
private struct ThreadScope {
    var conversation: Conversation.ID
    var thread: MessageThread.ID?

    /// For `conversationID = ? AND (? IS NULL OR threadID = ?)`, in that order.
    var arguments: [(any DatabaseValueConvertible)?] {
        [conversation.rawValue, thread?.rawValue, thread?.rawValue]
    }
}

/// What the stored messages say about one thread.
private struct ThreadStats {
    /// Replies not deleted. The first message is not among them: a summary
    /// counts it whether or not it is stored or deleted.
    var replies = 0
    /// The newest message not deleted: the thread's `lastActivity`.
    var newest: Date?
    /// The newest reply someone else sent, not deleted: the fallback's input.
    var newestReply: Date?
    /// The local member sent the first message or a reply, deleted or not.
    var participated = false
    /// A reply is stored, deleted or not: the thread gets a summary.
    var hasReply = false
}

/// A `thread` row: what the server said, `nil` where it said nothing.
private struct ThreadState {
    var messageCount: Int?
    var unreadCount: Int?
    var readPosition: Date?
    var markedUnreadAt: Date?
    var isFollowed: Bool?
}

private extension ChatStore {
    /// No `Date` is bound: every date here is read out of a REAL column.
    static func fetchThreadStats(
        _ scope: ThreadScope, me: Member.ID?, _ db: Database
    ) throws -> [MessageThread.ID: ThreadStats] {
        let mine: [(any DatabaseValueConvertible)?] = [me?.rawValue, me?.rawValue]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT threadID,
                SUM(CASE WHEN isDeleted = 0 AND isReply = 1 THEN 1 ELSE 0 END) AS replies,
                MAX(CASE WHEN isDeleted = 0 THEN createdAt END) AS newest,
                MAX(CASE WHEN isDeleted = 0 AND isReply = 1 AND sender IS NOT ?
                    THEN createdAt END) AS newestReply,
                MAX(CASE WHEN sender = ? THEN 1 ELSE 0 END) AS participated,
                MAX(isReply) AS hasReply
            FROM message
            WHERE conversationID = ? AND (? IS NULL OR threadID = ?)
            GROUP BY threadID
            """,
            arguments: StatementArguments(mine + scope.arguments)
        )
        var stats: [MessageThread.ID: ThreadStats] = [:]
        for row in rows {
            let newest: Double? = row["newest"]
            let newestReply: Double? = row["newestReply"]
            stats[MessageThread.ID(row["threadID"] as String)] = ThreadStats(
                replies: row["replies"], newest: newest.map(StoredDate.date),
                newestReply: newestReply.map(StoredDate.date),
                participated: row["participated"], hasReply: row["hasReply"]
            )
        }
        return stats
    }

    static func fetchThreadStates(
        _ scope: ThreadScope,
        _ db: Database
    ) throws -> [MessageThread.ID: ThreadState] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, messageCount, unreadCount, readPosition, markedUnreadAt, isFollowed FROM thread
            WHERE conversationID = ? AND (? IS NULL OR id = ?)
            """,
            arguments: StatementArguments(scope.arguments)
        )
        var states: [MessageThread.ID: ThreadState] = [:]
        for row in rows {
            let readPosition: Double? = row["readPosition"]
            let markedUnreadAt: Double? = row["markedUnreadAt"]
            states[MessageThread.ID(row["id"] as String)] = ThreadState(
                messageCount: row["messageCount"], unreadCount: row["unreadCount"],
                readPosition: readPosition.map(StoredDate.date),
                markedUnreadAt: markedUnreadAt.map(StoredDate.date), isFollowed: row["isFollowed"]
            )
        }
        return states
    }

    /// Distinct senders of the replies not deleted, each at their newest
    /// reply, newest first, at most `recentReplierLimit` per thread.
    static func fetchRecentRepliers(
        _ scope: ThreadScope,
        _ db: Database
    ) throws -> [MessageThread.ID: [Member.ID]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT threadID, sender, MAX(createdAt) AS latest FROM message
            WHERE conversationID = ? AND (? IS NULL OR threadID = ?) AND isReply = 1 AND isDeleted = 0
            GROUP BY threadID, sender
            ORDER BY threadID, latest DESC, sender
            """,
            arguments: StatementArguments(scope.arguments)
        )
        var repliers: [MessageThread.ID: [Member.ID]] = [:]
        for row in rows {
            let thread = MessageThread.ID(row["threadID"] as String)
            if repliers[thread, default: []].count < recentReplierLimit {
                repliers[thread, default: []].append(Member.ID(row["sender"] as String))
            }
        }
        return repliers
    }

    /// `replyCount` is the larger of what is stored and what the server
    /// counted, because the store holds pages; the stored side always counts
    /// the first message, which every thread has by definition, so a thread
    /// whose first message was deleted or never fetched loses nothing.
    /// `hasUnread` and `isFollowed` are `ThreadUnreadRule`'s answers, so
    /// `isFollowed` is never `nil` out of this read (ruling 1).
    static func summary(
        of key: ThreadKey, stats: ThreadStats, state: ThreadState, repliers: [Member.ID]
    ) -> MessageThread {
        var thread = MessageThread(
            id: key.thread, conversationID: key.conversation,
            replyCount: max(1 + stats.replies, state.messageCount ?? 0),
            lastActivity: stats.newest,
            isFollowed: state.isFollowed, readPosition: state.readPosition,
            markedUnreadAt: state.markedUnreadAt, unreadCount: state.unreadCount,
            recentRepliers: repliers
        )
        thread.hasUnread = ThreadUnreadRule.isUnread(
            thread, newestReplyAt: stats.newestReply, participated: stats.participated
        )
        thread.isFollowed = ThreadUnreadRule.isFollowed(thread, participated: stats.participated)
        return thread
    }
}
