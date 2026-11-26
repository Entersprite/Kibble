import ChatKit
import ChatRules
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
        try database.read(Self.fetchStoredConversations)
    }

    /// One canonical conversation, without decoding the account's entire world.
    func conversation(_ id: Conversation.ID) throws -> Conversation? {
        try database.read { db in
            guard let row = try ConversationRow.fetchOne(db, key: id.rawValue) else { return nil }
            let members = try MembershipRow.filter(Column("conversationID") == id.rawValue)
                .order(Column("position").asc).fetchAll(db).map { Member.ID($0.memberID) }
            return try row.conversation(members: members)
        }
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

    /// A bounded indexed directory lookup, without decoding the account directory.
    func members(identifiedBy ids: Set<Member.ID>) throws -> [Member] {
        guard ids.count <= 32 else { throw ChatError.unknown("Too many member lookups") }
        return try database.read { db in
            try MemberRow.filter(keys: ids.map(\.rawValue)).fetchAll(db).map { try $0.member }
        }
    }

    /// Who `ChatCommand.watchPresence` names when `conversation` is opened:
    /// people who posted in it, or the other person in a one-to-one DM, who
    /// have a member row - so `.setPresence` cannot drop the answer - and
    /// are not the local user.
    func presenceCandidates(in conversation: Conversation.ID) throws -> [Member.ID] {
        try database.read { db in
            let senders = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT sender FROM currentMessage AS message WHERE conversationID = ?
                UNION SELECT memberID FROM conversationMember WHERE conversationID = ?
                    AND conversationID IN (SELECT id FROM conversation WHERE kind = ?)
                """,
                arguments: [
                    conversation.rawValue,
                    conversation.rawValue,
                    Wire.string(Conversation.Kind.directMessage)
                ]
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

    /// Whether `conversation` holds a top-level message older than `date`:
    /// something the transcript shows before it. An opened search hit with
    /// none has nothing stored that led up to it
    /// (`SyncEngine.loadHistory(in:until:pageLimit:)`).
    func hasTopLevelMessage(in conversation: Conversation.ID, before date: Date) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (SELECT 1 FROM currentMessage AS message
                               WHERE conversationID = ? AND isReply = 0 AND createdAt < ?)
                """,
                arguments: [conversation.rawValue, StoredDate.value(date)]
            ) ?? false
        }
    }
}

// MARK: - Observing

public extension ChatStore {
    /// The sidebar, re-emitted whenever it changes.
    ///
    /// This is the seam between the database and SwiftUI: a view iterates one
    /// of these and never learns that a backend exists.
    ///
    /// **Duplicates are dropped.** Other store writes may still invalidate
    /// this observation without changing the conversation list.
    func observeConversations() -> AsyncValueObservation<[Conversation]> {
        ValueObservation.tracking(Self.fetchStoredConversations)
            .removeDuplicates().snapshotValues(in: database)
    }

    /// The directory, re-emitted when a member changes: a name, a photo,
    /// presence, status or calendar. One read per member write, never one per
    /// delivery of something else (`ChatSessionModel.watchDirectory()`).
    ///
    /// **Duplicates are dropped**, as `observeConversations` drops them:
    /// `clearEphemeralState` and a snapshot that names nobody new re-run the
    /// read and change no entry.
    func observeMembers() -> AsyncValueObservation<[Member]> {
        ValueObservation.tracking(Self.fetchMembers).removeDuplicates().snapshotValues(in: database)
    }

    /// The transcript, observed. Replies are left out (`fetchMessages`).
    func observeMessages(in conversation: Conversation.ID) -> AsyncValueObservation<[Message]> {
        ValueObservation
            .tracking { db in try Self.fetchMessages(conversation, db) }
            .snapshotValues(in: database)
    }

    func observeTypingMembers(
        in conversation: Conversation.ID
    ) -> AsyncValueObservation<[Member.ID]> {
        ValueObservation
            .tracking { db in try Self.fetchTyping(conversation, db) }
            .snapshotValues(in: database)
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

package extension ChatStore {
    /// The conversations as stored. The server's `hasUnreadThread` is kept for
    /// callers that need it; the sidebar uses the followed-thread overview's
    /// own badge rather than deriving a second flag on every message write.
    static func fetchStoredConversations(_ db: Database) throws -> [Conversation] {
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

    /// The transcript: one conversation's top-level messages, oldest first.
    ///
    /// **Replies are left out** (threads spec §4.1): they live in their
    /// thread's panel (`fetchThreadMessages`), and the conversation's own
    /// marks - automatic and from the sidebar (`newestServerMessage`) - read
    /// this, so they never cover a reply. A reply stored before v13 has
    /// `isReply = 0` and stays here until a history page rewrites it (§7).
    /// The Mentions reads do not come through here and keep every reply.
    static func fetchMessages(_ conversation: Conversation.ID, _ db: Database) throws -> [Message] {
        try MessageRow.currentHistory
            .filter(Column("conversationID") == conversation.rawValue && Column("isReply") == false)
            .order(Column("createdAt").asc, Column("id").asc)
            .fetchAll(db)
            .map { try $0.message }
    }

    static func fetchMessage(_ id: Message.ID, _ db: Database) throws -> Message? {
        try MessageRow.currentHistory
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
