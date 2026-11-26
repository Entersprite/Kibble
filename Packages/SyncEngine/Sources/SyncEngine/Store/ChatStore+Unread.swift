import ChatKit
import ChatRules
import GRDB

public struct UnreadInboxSnapshot: Sendable, Equatable {
    public internal(set) var messages: [Message] = []
    public internal(set) var readOnThisDevice: [Message] = []
    package var unreadThreadConversations: Set<Conversation.ID> = []
}

package extension ChatStore {
    func observeUnreadInbox() -> AsyncValueObservation<UnreadInboxSnapshot> {
        ValueObservation.tracking(Self.fetchUnreadInbox)
            .removeDuplicates()
            .snapshotValues(in: database)
    }

    func markInboxMessageRead(_ address: MessageAddress) throws {
        guard let id = address.message else { return }
        try database.write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO unreadInboxRead (messageID, conversationID, threadID, createdAt)
            SELECT message.id, message.conversationID,
                CASE WHEN message.isReply THEN message.threadID END, message.createdAt
            FROM currentMessage AS message JOIN conversation ON conversation.id = message.conversationID
            WHERE message.id = ? AND message.conversationID = ? AND message.threadID = ?
                AND message.isDeleted = 0 AND message.id NOT GLOB 'local/*'
                AND message.sender != (SELECT localMemberID FROM syncState WHERE id = 1)
            """, arguments: [id.rawValue, address.conversation.rawValue, address.thread?.rawValue])
        }
    }

    static func fetchUnreadInbox(_ db: Database) throws -> UnreadInboxSnapshot {
        guard let me = try fetchMe(db) else { return UnreadInboxSnapshot() }
        let rows = try Row.fetchCursor(db, sql: unreadInboxSQL, arguments: [me.rawValue])
        var snapshot = UnreadInboxSnapshot()
        snapshot.unreadThreadConversations = try Set(String.fetchAll(db, sql: """
        SELECT DISTINCT thread.conversationID FROM thread
        JOIN conversation ON conversation.id = thread.conversationID
        WHERE thread.unreadCount > 0 OR thread.markedUnreadAt IS NOT NULL
        """).map(Conversation.ID.init(rawValue:)))
        while let row = try rows.next() {
            let message = try MessageRow(row: row).message
            if row["readHere"] as Bool {
                snapshot.readOnThisDevice.append(message)
            } else {
                snapshot.messages.append(message)
            }
        }
        return snapshot
    }

    /// Count-only scopes need a confirmed head or a complete thread before older cached rows can qualify.
    /// An explicit unread mark establishes its own inclusive boundary.
    private static let unreadInboxSQL = """
    WITH scopes(conversationID, threadID, readAt, markAt, unreadCount, headAt) AS (
        SELECT id, NULL, lastReadAt, markedUnreadAt, NULLIF(unreadCount, 0), latestMainMessageAt
        FROM conversation
        WHERE (markedUnreadAt IS NOT NULL OR hasUnread = 1 OR unreadCount > 0)
            AND (markedUnreadAt IS NOT NULL OR lastReadAt IS NOT NULL OR (
                latestMainMessageAt IS NOT NULL AND EXISTS (
                    SELECT 1 FROM currentMessage AS head
                    WHERE head.conversationID = conversation.id AND head.isReply = 0
                        AND head.createdAt = conversation.latestMainMessageAt AND head.id NOT GLOB 'local/*'
                )
            ))
        UNION ALL
        SELECT thread.conversationID, thread.id, thread.readPosition, thread.markedUnreadAt,
            thread.unreadCount, NULL
        FROM thread JOIN conversation ON conversation.id = thread.conversationID
        WHERE thread.markedUnreadAt IS NOT NULL
            OR (thread.unreadCount > 0 AND (thread.readPosition IS NOT NULL OR (
                thread.messageCount > 0 AND thread.messageCount <= (
                        SELECT COUNT(*) FROM currentMessage AS cached
                        WHERE cached.conversationID = thread.conversationID AND cached.threadID = thread.id
                            AND cached.id NOT GLOB 'local/*'
                )
            )))
            OR (thread.unreadCount IS NULL AND thread.readPosition IS NOT NULL
                AND COALESCE(thread.isFollowed, EXISTS (
                    SELECT 1 FROM currentMessage AS mine
                    WHERE mine.conversationID = thread.conversationID AND mine.threadID = thread.id
                        AND mine.sender = ?1
                )))
    ),
    candidates AS (
        SELECT message.*, CASE WHEN markAt IS NULL
                THEN COALESCE(unreadCount, CASE WHEN readAt IS NULL THEN 1 END)
            END AS unreadLimit,
            ROW_NUMBER() OVER (
                PARTITION BY scopes.conversationID, scopes.threadID
                ORDER BY message.createdAt DESC, message.id DESC
            ) AS unreadRank
        FROM scopes CROSS JOIN currentMessage AS message ON message.conversationID = scopes.conversationID
        WHERE message.isDeleted = 0 AND message.sender != ?1 AND message.id NOT GLOB 'local/*'
                AND message.createdAt >= COALESCE(markAt, readAt, -1e99)
                AND CASE
                    WHEN markAt IS NOT NULL THEN message.createdAt >= markAt
                    WHEN readAt IS NOT NULL THEN message.createdAt > readAt
                        WHEN unreadCount IS NOT NULL THEN headAt IS NULL OR message.createdAt <= headAt
                    ELSE message.createdAt = headAt
                END
            AND ((scopes.threadID IS NULL AND message.isReply = 0)
                OR (scopes.threadID = message.threadID AND message.isReply = 1))
    )
    SELECT candidates.*, unreadInboxRead.messageID IS NOT NULL AS readHere
    FROM candidates LEFT JOIN unreadInboxRead ON unreadInboxRead.messageID = candidates.id
    WHERE unreadLimit IS NULL OR unreadRank <= unreadLimit
    ORDER BY candidates.createdAt, candidates.id
    """
}
