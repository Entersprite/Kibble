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
             .setMembership, .setReadState, .setPresence:
            try performConversationWrite(write, in: db)
        case .upsertMessage, .markMessageDeleted, .setReactions:
            try performMessageWrite(write, in: db)
        case .setTyping, .setConnectionState, .setLastError, .clearEphemeralState:
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
                try MemberRow(member).upsert(db)
            }
        case let .setMembership(conversation, members):
            try setMembership(conversation, members, in: db)
        case let .setReadState(conversation, lastReadAt, unread):
            try db.execute(
                sql: "UPDATE conversation SET unreadCount = ?, lastReadAt = ? WHERE id = ?",
                arguments: [unread, lastReadAt, conversation.rawValue]
            )
        case let .setPresence(member, presence):
            // An UPDATE rather than an upsert: presence for someone the store
            // has never heard of must not invent a member with no name, which
            // renders as a blank row.
            try db.execute(
                sql: "UPDATE member SET presence = ? WHERE id = ?",
                arguments: [Wire.string(presence), member.rawValue]
            )
        default:
            break
        }
    }

    private static func performMessageWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .upsertMessage(message):
            try MessageRow(message).upsert(db)
        case let .markMessageDeleted(id, _):
            // A tombstone, not a removal: the message keeps its place in the
            // ordering because the protocol keeps sending it and a hole would
            // break paging. A message the store never held is simply not here -
            // it holds pages, not all of history - so this is a no-op then.
            try db.execute(
                sql: "UPDATE message SET isDeleted = 1, text = '' WHERE id = ?",
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
        case .clearEphemeralState:
            try db.execute(sql: "DELETE FROM typing")
            try db.execute(sql: "UPDATE member SET presence = NULL")
        default:
            break
        }
    }

    private static func upsert(_ conversation: Conversation, in db: Database) throws {
        var row = try ConversationRow(conversation)
        // lastReadAt is the store's own column, not part of the domain model,
        // so a plain upsert would write NULL over a watermark the user set.
        // Carrying the existing value forward is cheaper to read than an
        // upsert with a hand-written assignment list, and harder to get wrong
        // when a column is added.
        row.lastReadAt = try Date.fetchOne(
            db,
            sql: "SELECT lastReadAt FROM conversation WHERE id = ?",
            arguments: [row.id]
        )
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
