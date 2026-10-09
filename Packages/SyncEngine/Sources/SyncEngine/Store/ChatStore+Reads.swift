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

    /// The transcript: one conversation's top-level messages, oldest first.
    /// Replies are left out (`fetchMessages`).
    func messages(in conversation: Conversation.ID) throws -> [Message] {
        try database.read { db in try Self.fetchMessages(conversation, db) }
    }

    /// One message by id, read straight from the database rather than from
    /// whatever a `ValueObservation` has last delivered.
    ///
    /// `ChatSessionModel.react` needs this: its observation of `messages`
    /// refreshes only after its tracked query re-runs, asynchronously, so a
    /// second toggle issued before that refresh would otherwise fold against a
    /// row `store.apply` has already superseded.
    func message(_ id: Message.ID) throws -> Message? {
        try database.read { db in try Self.fetchMessage(id, db) }
    }

    func members() throws -> [Member] {
        try database.read(Self.fetchMembers)
    }

    /// Who `ChatCommand.watchPresence` names when `conversation` is opened:
    /// people who posted in it, have a member row - so `.setPresence` cannot
    /// drop the answer - and are not the local user.
    func presenceCandidates(in conversation: Conversation.ID) throws -> [Member.ID] {
        try database.read { db in
            let senders = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT sender FROM message WHERE conversationID = ?",
                arguments: [conversation.rawValue]
            )
            let me = try Self.fetchMe(db)
            return try MemberRow.filter(keys: senders).order(Column("id").asc).fetchAll(db)
                .map { try $0.member }
                .filter { $0.kind == .human && $0.id != me }
                .map(\.id)
        }
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

    /// Your own availability, or `nil` before connect has said.
    func availability() throws -> Availability? {
        try database.read(Self.fetchAvailability)
    }

    /// The read position of one conversation: `Conversation.readPosition`,
    /// the same column, read without building the whole list.
    func lastReadAt(_ conversation: Conversation.ID) throws -> Date? {
        try database.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT lastReadAt FROM conversation WHERE id = ?",
                arguments: [conversation.rawValue]
            ).map(StoredDate.date)
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

    /// The transcript, observed. Replies are left out (`fetchMessages`).
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

    /// For `ChatSessionModel.availability`, the menu's checkmark.
    func observeAvailability() -> AsyncValueObservation<Availability?> {
        ValueObservation.tracking(Self.fetchAvailability).values(in: database)
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
        let unreadThreads = try fetchConversationsWithUnreadThreads(db)
        return try rows.map { row in
            let members = (byConversation[row.id] ?? []).map { Member.ID($0.memberID) }
            var conversation = try row.conversation(members: members)
            // Both sources, per CLAUDE.md's rule for a derived field (threads
            // spec §4.2): the server's flag, and the threads the store holds.
            if unreadThreads.contains(conversation.id) {
                conversation.hasUnreadThread = true
            }
            return conversation
        }
    }

    /// The transcript: one conversation's top-level messages, oldest first.
    ///
    /// **Replies are left out** (threads spec §4.1): they live in their
    /// thread's panel (`fetchThreadMessages`), and the conversation's own
    /// marks - automatic and from the sidebar (`newestServerMessage`) - read
    /// this, so they never cover a reply. A reply stored before v13 has
    /// `isReply = 0` and stays here until a history page rewrites it (§7).
    /// The Mentions reads do not come through here and keep every reply.
    static func fetchMessages(_ conversation: Conversation.ID, _ db: Database) throws -> [Message] {
        try MessageRow
            .filter(Column("conversationID") == conversation.rawValue && Column("isReply") == false)
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
            .map { try $0.message }
    }

    static func fetchMessage(_ id: Message.ID, _ db: Database) throws -> Message? {
        try MessageRow
            .filter(Column("id") == id.rawValue)
            .fetchOne(db)
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

    /// **One column, so an observation that reads `me` tracks only it.**
    /// `SyncStateRow.fetchOne` tracked every `syncState` column, so each
    /// connection-state, last-error and Mentions-backfill write re-ran the
    /// Mentions list and badge along with this. `.setLocalMember` writes this
    /// column, which is what still re-runs them when the account is
    /// identified (ruling 3).
    static func fetchMe(_ db: Database) throws -> Member.ID? {
        try String
            .fetchOne(db, sql: "SELECT localMemberID FROM syncState WHERE id = 1")
            .map { Member.ID($0) }
    }

    static func fetchAvailability(_ db: Database) throws -> Availability? {
        try String
            .fetchOne(db, sql: "SELECT availability FROM syncState WHERE id = 1")
            .map { try Wire.value(Availability.self, from: $0) }
    }
}
