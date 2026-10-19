import ChatKit
import ChatRules
import Foundation
import GRDB

/// Thread summaries (threads spec §4.1). Every answer `ThreadUnreadRule`
/// gives the store is computed from inputs that one SQL fragment defines
/// (`ruleInputs`).
///
/// **No `Date` is bound here**: every date is read out of a REAL column
/// (`StoredDate`'s rule).
package extension ChatStore {
    /// How many repliers a summary names: the mark draws three avatars.
    static let recentReplierLimit = 3

    /// `ThreadUnreadRule`'s two inputs from a thread's messages, as
    /// aggregates: the newest reply someone else sent, not deleted, and
    /// whether you sent any of its messages, deleted or not. One definition
    /// for all summaries. Binds `me` twice, ahead of anything else in the
    /// statement. The column names are `message`'s alone, so it reads the
    /// same inside a join with `thread`.
    private static let ruleInputs = """
    MAX(CASE WHEN isDeleted = 0 AND isReply = 1 AND sender IS NOT ? THEN createdAt END) AS newestReply,
    MAX(CASE WHEN sender = ? THEN 1 ELSE 0 END) AS participated
    """

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
        let summaries = try fetchSummaries(.conversation(conversation, only: thread), db)
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.key.thread, $0.value) })
    }

    /// Every thread the server says you follow (`isFollowed = 1`), summarized
    /// the way `fetchThreadSummaries` summarizes it: the same three queries,
    /// whatever the number of conversations. For the Threads list and its
    /// badge.
    static func fetchFollowedThreadSummaries(_ db: Database) throws -> [ThreadKey: MessageThread] {
        try fetchSummaries(.followed, db)
    }

    /// A summary for every thread in `scope` that has a stored reply or a
    /// `thread` row.
    private static func fetchSummaries(
        _ scope: ThreadScope,
        _ db: Database
    ) throws -> [ThreadKey: MessageThread] {
        let stats = try fetchThreadStats(scope, me: fetchMe(db), db)
        let states = try fetchThreadStates(scope, db)
        let repliers = try fetchRecentRepliers(scope, db)
        var summaries: [ThreadKey: MessageThread] = [:]
        for key in Set(stats.filter(\.value.hasReply).keys).union(states.keys) {
            summaries[key] = summary(
                of: key, stats: stats[key] ?? ThreadStats(), state: states[key] ?? ThreadState(),
                repliers: repliers[key] ?? []
            )
        }
        return summaries
    }
}

// MARK: - A summary's parts

/// Which messages and rows a summary read covers.
private enum ThreadScope {
    /// One conversation, or one thread of it.
    case conversation(Conversation.ID, only: MessageThread.ID?)
    /// Every thread the server says you follow, in any conversation.
    case followed

    /// The condition for a table whose thread id is in `threadColumn`, and
    /// its arguments in order.
    func condition(threadColumn: String) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        switch self {
        case let .conversation(conversation, thread):
            (
                "conversationID = ? AND (? IS NULL OR \(threadColumn) = ?)",
                [conversation.rawValue, thread?.rawValue, thread?.rawValue]
            )
        case .followed:
            (
                "(conversationID, \(threadColumn)) IN "
                    + "(SELECT conversationID, id FROM thread WHERE isFollowed = 1)",
                []
            )
        }
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

    init() {}

    /// From a row with the `thread` table's column names.
    init(_ row: Row) {
        let readPosition: Double? = row["readPosition"]
        let markedUnreadAt: Double? = row["markedUnreadAt"]
        messageCount = row["messageCount"]
        unreadCount = row["unreadCount"]
        self.readPosition = readPosition.map(StoredDate.date)
        self.markedUnreadAt = markedUnreadAt.map(StoredDate.date)
        isFollowed = row["isFollowed"]
    }

    /// The thread as the server stated it: every field `ThreadUnreadRule`
    /// reads, and nothing the stored messages add.
    func thread(_ key: ThreadKey) -> MessageThread {
        MessageThread(
            id: key.thread, conversationID: key.conversation, isFollowed: isFollowed,
            readPosition: readPosition, markedUnreadAt: markedUnreadAt, unreadCount: unreadCount
        )
    }
}

private extension ThreadKey {
    /// The address in a row's `conversationID` and `threadColumn`.
    init(_ row: Row, threadColumn: String) {
        self.init(
            conversation: Conversation.ID(row["conversationID"] as String),
            thread: MessageThread.ID(row[threadColumn] as String)
        )
    }
}

private extension ChatStore {
    static func fetchThreadStats(
        _ scope: ThreadScope, me: Member.ID?, _ db: Database
    ) throws -> [ThreadKey: ThreadStats] {
        let mine: [(any DatabaseValueConvertible)?] = [me?.rawValue, me?.rawValue]
        let condition = scope.condition(threadColumn: "threadID")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT conversationID, threadID,
                SUM(CASE WHEN isDeleted = 0 AND isReply = 1 THEN 1 ELSE 0 END) AS replies,
                MAX(CASE WHEN isDeleted = 0 THEN createdAt END) AS newest,
                \(ruleInputs),
                MAX(isReply) AS hasReply
            FROM currentMessage AS message
            WHERE \(condition.sql)
            GROUP BY conversationID, threadID
            """,
            arguments: StatementArguments(mine + condition.arguments)
        )
        var stats: [ThreadKey: ThreadStats] = [:]
        for row in rows {
            let newest: Double? = row["newest"]
            let newestReply: Double? = row["newestReply"]
            stats[ThreadKey(row, threadColumn: "threadID")] = ThreadStats(
                replies: row["replies"], newest: newest.map(StoredDate.date),
                newestReply: newestReply.map(StoredDate.date),
                participated: row["participated"], hasReply: row["hasReply"]
            )
        }
        return stats
    }

    static func fetchThreadStates(_ scope: ThreadScope, _ db: Database) throws -> [ThreadKey: ThreadState] {
        let condition = scope.condition(threadColumn: "id")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT conversationID, id, messageCount, unreadCount, readPosition, markedUnreadAt, isFollowed
            FROM thread WHERE \(condition.sql)
            """,
            arguments: StatementArguments(condition.arguments)
        )
        var states: [ThreadKey: ThreadState] = [:]
        for row in rows {
            states[ThreadKey(row, threadColumn: "id")] = ThreadState(row)
        }
        return states
    }

    /// Distinct senders of the replies not deleted, each at their newest
    /// reply, newest first, at most `recentReplierLimit` per thread.
    static func fetchRecentRepliers(_ scope: ThreadScope, _ db: Database) throws -> [ThreadKey: [Member.ID]] {
        let condition = scope.condition(threadColumn: "threadID")
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT conversationID, threadID, sender, MAX(createdAt) AS latest FROM currentMessage AS message
            WHERE \(condition.sql) AND isReply = 1 AND isDeleted = 0
            GROUP BY conversationID, threadID, sender
            ORDER BY conversationID, threadID, latest DESC, sender
            """,
            arguments: StatementArguments(condition.arguments)
        )
        var repliers: [ThreadKey: [Member.ID]] = [:]
        for row in rows {
            let key = ThreadKey(row, threadColumn: "threadID")
            if repliers[key, default: []].count < recentReplierLimit {
                repliers[key, default: []].append(Member.ID(row["sender"] as String))
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
        var thread = state.thread(key)
        thread.replyCount = max(1 + stats.replies, state.messageCount ?? 0)
        thread.lastActivity = stats.newest
        thread.recentRepliers = repliers
        thread.hasUnread = ThreadUnreadRule.isUnread(
            thread, newestReplyAt: stats.newestReply, participated: stats.participated
        )
        thread.isFollowed = ThreadUnreadRule.isFollowed(thread, participated: stats.participated)
        return thread
    }
}
