import ChatKit
import Foundation
import GRDB

// MARK: - Reading

public extension ChatStore {
    /// The sidebar, most recent first.
    ///
    /// `lastActivity == nil` sorts last, not as the epoch: "never, or not known
    /// yet" is what `Conversation` says it means, and SQLite orders NULL below
    /// everything under `DESC`, which is exactly that.
    func conversations() throws -> [Conversation] {
        try database.read(Self.fetchConversations)
    }

    func messages(in conversation: Conversation.ID) throws -> [Message] {
        try database.read { db in try Self.fetchMessages(conversation, db) }
    }

    func members() throws -> [Member] {
        try database.read(Self.fetchMembers)
    }

    func typingMembers(in conversation: Conversation.ID) throws -> [Member.ID] {
        try database.read { db in try Self.fetchTyping(conversation, db) }
    }

    func connectionState() throws -> ConnectionState {
        try database.read(Self.fetchConnectionState)
    }

    func lastError() throws -> ChatError? {
        try database.read(Self.fetchLastError)
    }

    /// Who the local user is, if a backend has ever said. Durable across
    /// launches: unlike `connectionState` and `lastError`, this is not a claim
    /// about *now*, so `clearEphemeralState` does not touch it.
    func me() throws -> Member.ID? {
        try database.read(Self.fetchMe)
    }

    /// The read watermark, which is not part of `Conversation` because it is a
    /// client-side bookmark rather than something the server describes.
    func lastReadAt(_ conversation: Conversation.ID) throws -> Date? {
        try database.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT lastReadAt FROM conversation WHERE id = ?",
                arguments: [conversation.rawValue]
            )
        }
    }
}

// MARK: - Observing

public extension ChatStore {
    /// The sidebar, re-emitted whenever it changes.
    ///
    /// This is the seam between the database and SwiftUI: a view iterates one
    /// of these and never learns that a backend exists.
    func observeConversations() -> AsyncValueObservation<[Conversation]> {
        ValueObservation.tracking(Self.fetchConversations).values(in: database)
    }

    func observeMessages(in conversation: Conversation.ID) -> AsyncValueObservation<[Message]> {
        ValueObservation
            .tracking { db in try Self.fetchMessages(conversation, db) }
            .values(in: database)
    }

    func observeTypingMembers(
        in conversation: Conversation.ID
    ) -> AsyncValueObservation<[Member.ID]> {
        ValueObservation
            .tracking { db in try Self.fetchTyping(conversation, db) }
            .values(in: database)
    }

    /// For the connection banner. A UI that reads this instead of asking a
    /// backend keeps working when the backend is swapped for another one.
    func observeConnectionState() -> AsyncValueObservation<ConnectionState> {
        ValueObservation.tracking(Self.fetchConnectionState).values(in: database)
    }

    /// For `ChatSessionModel.me`, which watches this the way it watches every
    /// other store-fed property rather than taking it once at init.
    func observeMe() -> AsyncValueObservation<Member.ID?> {
        ValueObservation.tracking(Self.fetchMe).values(in: database)
    }

    /// For the error banner, and it is the half that was missing.
    ///
    /// `setLastError` had a writer, a one-shot read and no observation, so
    /// every recorded failure - a refused send, a backend error, a page of
    /// history that would not load - landed in the database and was never
    /// drawn. The only thing that ever set `ChatSessionModel.lastError` was an
    /// *observation* itself throwing, which is the one failure that does not
    /// go through `SyncEngine.record`. A store the UI reads is only a seam if
    /// the UI reads all of it.
    func observeLastError() -> AsyncValueObservation<ChatError?> {
        ValueObservation.tracking(Self.fetchLastError).values(in: database)
    }
}

// MARK: - The queries themselves

extension ChatStore {
    /// Shared by the one-shot reads and the observations, so the two can never
    /// answer differently.
    static func fetchConversations(_ db: Database) throws -> [Conversation] {
        let rows = try ConversationRow
            .order(Column("lastActivity").desc, Column("id").asc)
            .fetchAll(db)
        let membership = try MembershipRow
            .order(Column("position").asc)
            .fetchAll(db)
        let byConversation = Dictionary(grouping: membership, by: \.conversationID)
        return try rows.map { row in
            let members = (byConversation[row.id] ?? []).map { Member.ID($0.memberID) }
            return try row.conversation(members: members)
        }
    }

    static func fetchMessages(_ conversation: Conversation.ID, _ db: Database) throws -> [Message] {
        try MessageRow
            .filter(Column("conversationID") == conversation.rawValue)
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
            .map { try $0.message }
    }

    static func fetchMembers(_ db: Database) throws -> [Member] {
        try MemberRow.order(Column("id").asc).fetchAll(db).map { try $0.member }
    }

    static func fetchTyping(_ conversation: Conversation.ID, _ db: Database) throws -> [Member.ID] {
        try TypingRow
            .filter(Column("conversationID") == conversation.rawValue)
            .order(Column("memberID").asc)
            .fetchAll(db)
            .map { Member.ID($0.memberID) }
    }

    static func fetchConnectionState(_ db: Database) throws -> ConnectionState {
        guard let row = try SyncStateRow.fetchOne(db) else { return .idle }
        return try Wire.value(ConnectionState.self, from: row.connectionState)
    }

    static func fetchLastError(_ db: Database) throws -> ChatError? {
        guard let raw = try SyncStateRow.fetchOne(db)?.lastError else { return nil }
        return try Wire.value(ChatError.self, from: raw)
    }

    static func fetchMe(_ db: Database) throws -> Member.ID? {
        guard let raw = try SyncStateRow.fetchOne(db)?.localMemberID else { return nil }
        return Member.ID(raw)
    }
}
