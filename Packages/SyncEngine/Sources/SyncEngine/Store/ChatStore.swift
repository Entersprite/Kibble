import ChatKit
import Foundation
import GRDB

/// The database the UI observes.
///
/// Views read this and never a backend. That one rule is what buys instant cold
/// launch, catch-up on wake, and a UI that cannot tell an in-process bridge from
/// a remote one - the three things the architecture asks a local store for.
///
/// Writes arrive as `[StoreWrite]` and are applied in **one transaction per
/// batch**, because a batch is one event: a sidebar must never render a
/// conversation whose messages have not landed yet.
public final class ChatStore: Sendable {
    let database: any DatabaseWriter
    let decodedTranscriptCache = DecodedTranscriptCache()

    /// Opens or creates the database at `path` and migrates it.
    public static func onDisk(at path: String) throws -> ChatStore {
        try ChatStore(DatabaseQueue(path: path))
    }

    /// A database that exists only for as long as this object does. Used by
    /// tests, and by anything that wants a throwaway store.
    public static func inMemory() throws -> ChatStore {
        try ChatStore(DatabaseQueue())
    }

    init(_ database: any DatabaseWriter) throws {
        self.database = database
        try Schema.migrator.migrate(database)
    }
}

// MARK: - Writing

public extension ChatStore {
    /// Applies a batch atomically. Either every write lands or none does.
    func apply(_ writes: [StoreWrite]) throws {
        try database.write { db in
            for write in writes {
                try Self.perform(write, in: db)
            }
        }
    }

    private static func perform(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case .setScopedTyping, .setReadReceipts, .clearActivityTyping:
            try performActivityWrite(write, in: db)
        case .removeConversation, .setConversationUnreadMark:
            try performConversationActionWrite(write, in: db)
        case .replaceConversations, .upsertConversation, .restoreConversation, .upsertMembers, .setMembership:
            try performConversationWrite(write, in: db)
        case .setPresence, .setStatus, .setCalendar:
            try performMemberWrite(write, in: db)
        case .setReadState, .markUnread:
            try performReadWrite(write, in: db)
        case .applyThreadChange, .setUnreadThreads:
            try performThreadWrite(write, in: db)
        case .upsertMessage, .upsertMessageKeepingReactions, .insertMessageIfAbsent, .markMessageDeleted,
             .removeMessage, .reconcileThread, .setReactions:
            try performMessageWrite(write, in: db)
        case .setTyping, .setConnectionState, .setLastError, .setLocalMember, .setMentionBackfill,
             .setAvailability, .clearEphemeralState:
            try performSessionWrite(write, in: db)
        }
    }

    /// A claim about one person, written by an UPDATE so that nobody the
    /// store has never named is invented as a nameless row.
    private static func performMemberWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .setPresence(member, presence):
            // An UPDATE rather than an upsert: presence for someone the store
            // has never heard of must not invent a member with no name, which
            // renders as a blank row.
            try db.execute(
                sql: "UPDATE member SET presence = ? WHERE id = ?",
                arguments: [Wire.string(presence), member.rawValue]
            )
        case let .setStatus(member, status):
            // An UPDATE, for `.setPresence`'s reason.
            try db.execute(
                sql: "UPDATE member SET status = ? WHERE id = ?",
                arguments: [status.map(Wire.json), member.rawValue]
            )
        case let .setCalendar(member, schedule):
            // An UPDATE, for `.setPresence`'s reason.
            try db.execute(
                sql: "UPDATE member SET calendar = ? WHERE id = ?",
                arguments: [schedule.map(Wire.json), member.rawValue]
            )
        default:
            break
        }
    }

    private static func performConversationWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .replaceConversations(conversations):
            let keep = conversations.map(\.id.rawValue)
            // Membership goes with them, by cascade. Messages deliberately do
            // not: history is expensive to re-fetch, an orphaned message is
            // invisible because nothing renders a conversation that is gone,
            // and it comes back for free if the conversation returns.
            try ConversationRow.filter(!keep.contains(Column("id"))).deleteAll(db)
            for conversation in conversations {
                try upsert(conversation, in: db)
            }
        case let .restoreConversation(conversation):
            try db.execute(
                sql: "UPDATE conversationActionState SET isRemoved = 0 WHERE id = ?",
                arguments: [conversation.id.rawValue]
            )
            try upsert(conversation, in: db)
        case let .upsertConversation(conversation):
            try upsert(conversation, in: db)
        case let .upsertMembers(members):
            for member in members {
                var row = try MemberRow(member)
                // The `lastReadAt` rule, for presence, status and calendar: a snapshot
                // that carries none - every `get_members` answer - says
                // nothing about them, so what `.setPresence` and `.setStatus`
                // recorded is carried forward rather than overwritten with
                // NULL. Only `clearEphemeralState`, and a `.setStatus(nil)`,
                // clear them.
                if row.presence == nil || row.status == nil || row.calendar == nil,
                   let stored = try Row.fetchOne(
                       db,
                       sql: "SELECT presence, status, calendar FROM member WHERE id = ?",
                       arguments: [row.id]
                   ) {
                    row.presence = row.presence ?? stored["presence"]
                    row.status = row.status ?? stored["status"]
                    row.calendar = row.calendar ?? stored["calendar"]
                }
                try row.upsert(db)
            }
        case let .setMembership(conversation, members):
            try setMembership(conversation, members, in: db)
        default:
            break
        }
    }

    private static func performMessageWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .upsertMessageKeepingReactions(message):
            var kept = message
            // A tombstone takes its own (empty) reactions rather than what is
            // stored - see `StoreWrite.upsertMessageKeepingReactions`'s doc
            // comment for why a deletion arrives through this same case.
            if !message.isDeleted, let stored = try String.fetchOne(
                db, sql: "SELECT reactions FROM message WHERE id = ?", arguments: [message.id.rawValue]
            ) {
                kept.reactions = try Wire.value([Reaction].self, from: stored)
            }
            try performMessageWrite(.upsertMessage(kept), in: db)
            try advanceConversationActivity(kept, in: db)
        case let .upsertMessage(message):
            try upsertUnclearedMessage(message, in: db)
        case let .insertMessageIfAbsent(message):
            try insertUnclearedMessageIfAbsent(message, in: db)
        case let .markMessageDeleted(id, _):
            // A tombstone, not a removal: the message keeps its place in the
            // ordering because the protocol keeps sending it and a hole would
            // break paging. A message the store never held is simply not here -
            // it holds pages, not all of history - so this is a no-op then.
            // Its mentions go with its text: a tombstone mentions nobody. And
            // its reactions: a tombstone offers no toggles. Its links and cards
            // go too: a tombstone points nowhere (links spec §5).
            try db.execute(
                sql: """
                UPDATE message SET isDeleted = 1, text = '', mentions = '[]', reactions = '[]',
                                   links = '[]', cards = '[]'
                WHERE id = ? AND (isDeleted <> 1 OR text <> '' OR mentions <> '[]'
                    OR reactions <> '[]' OR links <> '[]' OR cards <> '[]')
                """,
                arguments: [id.rawValue]
            )
        case let .removeMessage(id):
            // Gone, not tombstoned: nothing was ever posted, so there is no
            // place in the ordering to keep.
            //
            // By id, never by `localID`. The server echoes the client's
            // `localID` back onto the delivered message, so a `localID` delete
            // would take the real row whenever the echo beat the failure -
            // which is exactly what a lost response to a POST that landed
            // looks like. A row that is already gone is a no-op, which is what
            // makes this safe in that case rather than merely lucky.
            try db.execute(
                sql: "DELETE FROM message WHERE id = ?",
                arguments: [id.rawValue]
            )
        case let .reconcileThread(thread, conversation, keeping):
            try reconcileThread(thread, in: conversation, keeping: keeping, db: db)
        case let .setReactions(messageID, reactions):
            let existing = try String.fetchOne(
                db, sql: "SELECT reactions FROM message WHERE id = ?", arguments: [messageID.rawValue]
            )
            if let existing, try Wire.value([Reaction].self, from: existing) != reactions {
                try db.execute(
                    sql: "UPDATE message SET reactions = ? WHERE id = ?",
                    arguments: [Wire.json(reactions), messageID.rawValue]
                )
            }
        default:
            break
        }
    }

    private static func reconcileThread(
        _ thread: MessageThread.ID, in conversation: Conversation.ID, keeping: [Message.ID], db: Database
    ) throws {
        let placeholders = Array(repeating: "?", count: keeping.count).joined(separator: ",")
        let exclusion = keeping.isEmpty ? "" : " AND id NOT IN (\(placeholders))"
        try db.execute(
            sql: """
            DELETE FROM message
            WHERE conversationID = ? AND threadID = ? AND id NOT LIKE 'local/%'\(exclusion)
            """,
            arguments: StatementArguments(
                [conversation.rawValue, thread.rawValue] + keeping.map(\.rawValue)
            )
        )
    }

    private static func performSessionWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .setTyping(conversation, member, isTyping):
            let row = TypingRow(conversationID: conversation.rawValue, memberID: member.rawValue)
            if isTyping {
                try row.upsert(db)
            } else {
                try row.delete(db)
            }
        case let .setConnectionState(state):
            try db.execute(
                sql: "UPDATE syncState SET connectionState = ? WHERE id = 1",
                arguments: [Wire.json(state)]
            )
        case let .setLastError(error):
            try db.execute(
                sql: "UPDATE syncState SET lastError = ? WHERE id = 1",
                arguments: [error.map(Wire.json)]
            )
        case let .setLocalMember(id):
            try db.execute(
                sql: "UPDATE syncState SET localMemberID = ? WHERE id = 1",
                arguments: [id.rawValue]
            )
        case let .setAvailability(availability):
            try db.execute(
                sql: "UPDATE syncState SET availability = ? WHERE id = 1",
                arguments: [Wire.json(availability)]
            )
        case let .setMentionBackfill(status):
            try setMentionBackfill(status, in: db)
        case .clearEphemeralState:
            try db.execute(sql: "DELETE FROM activityTyping")
            try db.execute(sql: "DELETE FROM receiptAvailability")
            try db.execute(sql: "DELETE FROM readReceipt")
            try db.execute(sql: "DELETE FROM typing")
            try db.execute(sql: "UPDATE member SET presence = NULL, status = NULL, calendar = NULL")
            // The connection state, the last error, your availability and the
            // Mentions backfill's status are claims about now too. A fresh process that has not
            // connected must not inherit "connected" from whatever the last
            // one wrote, and has not started a backfill run.
            //
            // localMemberID is deliberately untouched: unlike the columns
            // above, who the local user is stays true across a relaunch.
            try db.execute(
                sql: """
                UPDATE syncState SET connectionState = ?, lastError = NULL, availability = NULL,
                    mentionBackfillRunning = 0, mentionBackfillFailed = 0
                WHERE id = 1
                """,
                arguments: [Wire.json(ConnectionState.idle)]
            )
        default:
            break
        }
    }
}

// MARK: - Erasing

public extension ChatStore {
    /// Wipes every row and every table, then restores the schema empty.
    ///
    /// Goes through GRDB's own `erase()` rather than a hand-written sequence
    /// of `DELETE FROM` statements. A hand-written list is exactly the kind
    /// of list a table added later gets left off, and this database is
    /// shared by every account that ever signs in on one Mac - see
    /// `AppEnvironment.signOut()`'s doc comment for why forgetting one is
    /// "the next account inherits rows that are not theirs" rather than
    /// merely untidy.
    ///
    /// `erase()` drops the schema entirely, including GRDB's own migration
    /// bookkeeping, so the migrator is re-run in the same call. Without that,
    /// the store would come back with no tables at all, and the very next
    /// read - even one from a task that outlived whatever called this -
    /// would fail with "no such table" instead of finding an empty,
    /// well-shaped database.
    func erase() throws {
        decodedTranscriptCache.removeAll()
        try database.erase()
        try Schema.migrator.migrate(database)
        decodedTranscriptCache.removeAll()
    }
}
