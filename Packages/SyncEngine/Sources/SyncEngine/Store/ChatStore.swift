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
        case .replaceConversations, .upsertConversation, .upsertMembers,
             .setMembership, .setPresence, .setStatus:
            try performConversationWrite(write, in: db)
        case .setReadState, .markUnread:
            try performReadWrite(write, in: db)
        case .upsertMessage, .upsertMessageKeepingReactions, .markMessageDeleted, .removeMessage,
             .setReactions:
            try performMessageWrite(write, in: db)
        case .setTyping, .setConnectionState, .setLastError, .setLocalMember, .setMentionBackfill,
             .clearEphemeralState:
            try performSessionWrite(write, in: db)
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
        case let .upsertConversation(conversation):
            try upsert(conversation, in: db)
        case let .upsertMembers(members):
            for member in members {
                var row = try MemberRow(member)
                // The `lastReadAt` rule, for presence and status: a snapshot
                // that carries none - every `get_members` answer - says
                // nothing about them, so what `.setPresence` and `.setStatus`
                // recorded is carried forward rather than overwritten with
                // NULL. Only `clearEphemeralState`, and a `.setStatus(nil)`,
                // clear them.
                if row.presence == nil || row.status == nil,
                   let stored = try Row.fetchOne(
                       db, sql: "SELECT presence, status FROM member WHERE id = ?", arguments: [row.id]
                   ) {
                    row.presence = row.presence ?? stored["presence"]
                    row.status = row.status ?? stored["status"]
                }
                try row.upsert(db)
            }
        case let .setMembership(conversation, members):
            try setMembership(conversation, members, in: db)
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
        default:
            break
        }
    }

    /// Read state and the unread flag - the two writes that move `hasUnread`.
    ///
    /// Split from `performConversationWrite(_:in:)` because adding
    /// `.markUnread` took that function to `swiftlint`'s cyclomatic-complexity
    /// limit of 10. It is a real seam rather than an arbitrary cut: these two
    /// are the **only** writes that touch `hasUnread`, and they are the pair
    /// that has to stay consistent - the flag shipped with nothing clearing it
    /// (`findings.md` §37.8), so keeping them adjacent is the point.
    private static func performReadWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .setReadState(conversation, lastReadAt, unread):
            // `hasUnread` is cleared here, and this is the only thing that
            // clears it. Correct by construction rather than by convention:
            // §36 requires the position a client publishes to be one
            // microsecond *past* the newest message it has actually seen, so
            // an acknowledged read state means there is nothing newer left to
            // be unread about. A `GROUP_VIEWED` event from another device
            // (§34) arrives on this same path and clears it for the same
            // reason.
            //
            // The position is bound through `StoredDate`, never as the `Date`
            // itself: a bound `Date` is GRDB's millisecond text whatever the
            // records' strategy says, which would truncate the watermark and
            // leave a text value in a column of numbers.
            try db.execute(
                sql: """
                UPDATE conversation
                SET unreadCount = ?, lastReadAt = ?, hasUnread = 0
                WHERE id = ?
                """,
                arguments: [unread, StoredDate.value(lastReadAt), conversation.rawValue]
            )
        case let .markUnread(conversation, sender):
            // The local user's own message never marks their conversation
            // unread - see `StoreWrite.markUnread`'s doc comment for why the
            // comparison happens here rather than in the reducer.
            let localMember = try String.fetchOne(
                db, sql: "SELECT localMemberID FROM syncState WHERE id = 1"
            )
            guard localMember != sender.rawValue else { break }
            try db.execute(
                sql: "UPDATE conversation SET hasUnread = 1 WHERE id = ?",
                arguments: [conversation.rawValue]
            )
        default:
            // `perform(_:in:)` routes only the two cases above here. Kept
            // rather than made exhaustive because `StoreWrite` gains cases
            // often, and each one should be a decision in `perform(_:in:)`
            // rather than a compile error in every branch function.
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
        case let .upsertMessage(message):
            // An optimistic copy and its echo are the same message with two
            // different ids: the client invented one, the server assigned the
            // other. Keyed on `localID`, which the server echoes back and which
            // is `nil` on everyone else's messages - so this can never merge two
            // messages that merely both lack one.
            //
            // The `id <> ?` clause is what keeps an ordinary re-delivery of the
            // same server message from deleting the row it is about to write.
            if let localID = message.localID {
                try db.execute(
                    sql: "DELETE FROM message WHERE localID = ? AND id <> ?",
                    arguments: [localID, message.id.rawValue]
                )
            }
            try MessageRow(message).upsert(db)
        case let .markMessageDeleted(id, _):
            // A tombstone, not a removal: the message keeps its place in the
            // ordering because the protocol keeps sending it and a hole would
            // break paging. A message the store never held is simply not here -
            // it holds pages, not all of history - so this is a no-op then.
            // Its mentions go with its text: a tombstone mentions nobody. And
            // its reactions: a tombstone offers no toggles.
            try db.execute(
                sql: """
                UPDATE message SET isDeleted = 1, text = '', mentions = '[]', reactions = '[]'
                WHERE id = ?
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
        case let .setReactions(messageID, reactions):
            try db.execute(
                sql: "UPDATE message SET reactions = ? WHERE id = ?",
                arguments: [Wire.json(reactions), messageID.rawValue]
            )
        default:
            break
        }
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
        case let .setMentionBackfill(status):
            try db.execute(
                sql: """
                UPDATE syncState SET mentionBackfillRunning = ?, mentionBackfillFailed = ?
                WHERE id = 1
                """,
                arguments: [status.running, status.failedConversations]
            )
        case .clearEphemeralState:
            try db.execute(sql: "DELETE FROM typing")
            try db.execute(sql: "UPDATE member SET presence = NULL, status = NULL")
            // The connection state, the last error and the Mentions backfill's
            // status are claims about now too. A fresh process that has not
            // connected must not inherit "connected" from whatever the last
            // one wrote, and has not started a backfill run.
            //
            // localMemberID is deliberately untouched: unlike the columns
            // above, who the local user is stays true across a relaunch.
            try db.execute(
                sql: """
                UPDATE syncState SET connectionState = ?, lastError = NULL,
                    mentionBackfillRunning = 0, mentionBackfillFailed = 0
                WHERE id = 1
                """,
                arguments: [Wire.json(ConnectionState.idle)]
            )
        default:
            break
        }
    }

    private static func upsert(_ conversation: Conversation, in db: Database) throws {
        var row = try ConversationRow(conversation)
        // `lastReadAt` is `Conversation.readPosition` (the mentions-list spec
        // §1). A snapshot that carries one is authoritative: a world load's is
        // Google's current read state. One that carries none - a world item
        // with no `last_read_time`, a fixture's `conversationUpdated` - says
        // nothing about the position, so the value `.setReadState` recorded is
        // carried forward rather than overwritten with NULL.
        if row.lastReadAt == nil {
            row.lastReadAt = try Double.fetchOne(
                db,
                sql: "SELECT lastReadAt FROM conversation WHERE id = ?",
                arguments: [row.id]
            ).map(StoredDate.date)
        }
        try row.upsert(db)
        try setMembership(conversation.id, conversation.members, in: db)
    }

    private static func setMembership(
        _ conversation: Conversation.ID,
        _ members: [Member.ID],
        in db: Database
    ) throws {
        try MembershipRow
            .filter(Column("conversationID") == conversation.rawValue)
            .deleteAll(db)
        for (position, member) in members.enumerated() {
            try MembershipRow(
                conversationID: conversation.rawValue,
                memberID: member.rawValue,
                position: position
            ).insert(db)
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
        try database.erase()
        try Schema.migrator.migrate(database)
    }
}
