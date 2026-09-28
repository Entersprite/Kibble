import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// The store keeps every date to the microsecond.
///
/// GRDB's default `Date` column is the text `yyyy-MM-dd HH:mm:ss.SSS`, which
/// keeps milliseconds only - rounded to the nearest, so `.1284` and `.128263`
/// both store as `.128` while `.1289` stores as `.129`. Mark-read takes its
/// position from messages read back out of this store, so a message at
/// `.128263` was marked at `.128001` - before the message itself - and Google
/// kept the conversation unread (a live probe measured GChat's own mark
/// landing 262 µs short). Every value here is chosen so that a millisecond
/// store gets it wrong.
struct StoreDatePrecisionTests {
    private let conversation = Conversation(id: Conversation.ID("space/s"), kind: .space)
    /// `.128263`: not on a millisecond, which is the whole point.
    private let precise = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func message(_ id: String, at createdAt: Date, editedAt: Date? = nil) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation.id, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "hi", createdAt: createdAt, editedAt: editedAt
        )
    }

    // MARK: Round trips

    @Test func aMessagesCreationTimeSurvivesTheStoreToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([conversation]), .upsertMessage(message("m:1", at: precise))])
        let stored = try store.messages(in: conversation.id).first
        #expect(microseconds(stored?.createdAt) == 1_790_000_000_128_263)
    }

    @Test func aMessagesEditTimeSurvivesTheStoreToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        let edited = Date(timeIntervalSince1970: 1_790_000_060.000_417)
        try store.apply([
            .replaceConversations([conversation]),
            .upsertMessage(message("m:1", at: precise, editedAt: edited))
        ])
        let stored = try store.messages(in: conversation.id).first
        #expect(microseconds(stored?.editedAt) == 1_790_000_060_000_417)
    }

    /// `.setReadState` binds its position into raw SQL, so this is the one
    /// write the records' encoding strategy does not reach.
    @Test func aReadPositionSurvivesTheStoreToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([conversation]),
            .setReadState(conversation: conversation.id, lastReadAt: precise, unread: 0)
        ])
        #expect(try microseconds(store.lastReadAt(conversation.id)) == 1_790_000_000_128_263)
    }

    /// A conversation upsert carries the store's own watermark forward by
    /// reading it back first. That read must not truncate it either.
    @Test func aReadPositionSurvivesALaterConversationUpsert() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([conversation]),
            .setReadState(conversation: conversation.id, lastReadAt: precise, unread: 0),
            .upsertConversation(conversation)
        ])
        #expect(try microseconds(store.lastReadAt(conversation.id)) == 1_790_000_000_128_263)
    }

    @Test func aConversationsLastActivitySurvivesTheStoreToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        var active = conversation
        active.lastActivity = precise
        try store.apply([.replaceConversations([active])])
        #expect(try microseconds(store.conversations().first?.lastActivity) == 1_790_000_000_128_263)
    }

    // MARK: The comparisons

    /// `messages(in:)` orders by `createdAt`. Two messages inside one
    /// millisecond, with ids in the opposite order to their times: a
    /// millisecond store ties them and the id tiebreak puts them backwards.
    @Test func messagesInOneMillisecondAreOrderedByTheirMicroseconds() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([conversation]),
            .upsertMessage(message("m:a", at: Date(timeIntervalSince1970: 1_790_000_000.128400))),
            .upsertMessage(message("m:b", at: precise))
        ])
        #expect(try store.messages(in: conversation.id).map(\.id.rawValue) == ["m:b", "m:a"])
    }

    /// The sidebar orders by `lastActivity`, newest first - the same tie,
    /// the other direction.
    @Test func conversationsActiveInOneMillisecondAreOrderedByTheirMicroseconds() throws {
        let store = try ChatStore.inMemory()
        var earlier = Conversation(id: Conversation.ID("space/a"), kind: .space)
        earlier.lastActivity = precise
        var later = Conversation(id: Conversation.ID("space/b"), kind: .space)
        later.lastActivity = Date(timeIntervalSince1970: 1_790_000_000.128400)
        try store.apply([.replaceConversations([earlier, later])])
        #expect(try store.conversations().map(\.id.rawValue) == ["space/b", "space/a"])
    }
}

/// The microsecond a date names, rounded the way `Microseconds.from` rounds.
func microseconds(_ date: Date?) -> Int64? {
    date.map { Int64(($0.timeIntervalSince1970 * 1_000_000).rounded()) }
}
