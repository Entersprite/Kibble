import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// The `thread` table's writes (threads spec §4.1), read back raw so these
/// tests do not lean on the summary read they feed.
struct StoreThreadWriteTests {
    private let space = Conversation.ID("space/s")
    private let topic = MessageThread.ID("topic:1")
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    /// Off a millisecond on purpose (`StoreDatePrecisionTests`).
    private let precise = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func change(_ change: ThreadChange) -> StoreWrite {
        .applyThreadChange(thread: topic, conversation: space, change: change)
    }

    private func reply(_ id: String, from sender: Member.ID, at createdAt: Date) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: topic, sender: sender, text: "re",
            createdAt: createdAt, isReply: true
        )
    }

    /// One column of the stored row, or `nil` when the row or its value is absent.
    private func value<Value: DatabaseValueConvertible>(
        _ column: String, in store: ChatStore
    ) throws -> Value? {
        try store.database.read { db in
            try Value.fetchOne(
                db,
                sql: "SELECT \(column) FROM thread WHERE conversationID = ? AND id = ?",
                arguments: [space.rawValue, topic.rawValue]
            )
        }
    }

    private func int(_ column: String, in store: ChatStore) throws -> Int? {
        try value(column, in: store)
    }

    private func bool(_ column: String, in store: ChatStore) throws -> Bool? {
        try value(column, in: store)
    }

    /// The stored REAL, to the microsecond.
    private func micros(_ column: String, in store: ChatStore) throws -> Int64? {
        let seconds: Double? = try value(column, in: store)
        return microseconds(seconds.map(StoredDate.date))
    }

    /// The first fact about a thread creates its row: an UPDATE would have
    /// dropped it, and a thread's facts arrive in any order.
    @Test func theFirstFactAboutAThreadCreatesItsRow() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.followed(true))])
        #expect(try bool("isFollowed", in: store) == true)
        #expect(try int("messageCount", in: store) == nil)
    }

    @Test func countedReplacesBothCountsAndKeepsTheUnreadOneWhenItDoesNotSay() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.counted(messages: 3, unread: 2))])
        try store.apply([change(.counted(messages: 4, unread: nil))])
        #expect(try int("messageCount", in: store) == 4)
        #expect(try int("unreadCount", in: store) == 2)
        try store.apply([change(.counted(messages: 4, unread: 0))])
        #expect(try int("unreadCount", in: store) == 0)
    }

    /// A later read moves the position; an earlier one never moves it back.
    @Test func aReadKeepsTheLaterPositionToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.read(upTo: precise))])
        #expect(try micros("readPosition", in: store) == 1_790_000_000_128_263)
        try store.apply([change(.read(upTo: precise.addingTimeInterval(-60)))])
        #expect(try micros("readPosition", in: store) == 1_790_000_000_128_263)
        try store.apply([change(.read(upTo: precise.addingTimeInterval(60)))])
        #expect(try micros("readPosition", in: store) == 1_790_000_060_128_263)
    }

    /// "Covers" is `>=`: a read equal to the newest reply from someone else
    /// zeroes the server's count, and one a microsecond short does not.
    @Test func aReadThatCoversTheNewestReplyZeroesTheCountAndEqualityCovers() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .setLocalMember(me),
            .upsertMessage(reply("m:1", from: alice, at: precise)),
            change(.counted(messages: 2, unread: 1))
        ])
        try store.apply([change(.read(upTo: Date(timeIntervalSince1970: 1_790_000_000.128262)))])
        #expect(try int("unreadCount", in: store) == 1)
        try store.apply([change(.read(upTo: precise))])
        #expect(try int("unreadCount", in: store) == 0)
    }

    /// Ruling 3: your own newer reply and a newer tombstone do not keep it.
    @Test func myOwnNewerReplyAndADeletedOneDoNotKeepTheCount() throws {
        var gone = reply("m:gone", from: alice, at: precise.addingTimeInterval(120))
        gone.isDeleted = true
        let store = try ChatStore.inMemory()
        try store.apply([
            .setLocalMember(me),
            .upsertMessage(reply("m:1", from: alice, at: precise)),
            .upsertMessage(reply("m:mine", from: me, at: precise.addingTimeInterval(60))),
            .upsertMessage(gone),
            change(.counted(messages: 4, unread: 3))
        ])
        try store.apply([change(.read(upTo: precise))])
        #expect(try int("unreadCount", in: store) == 0)
    }

    /// A count nobody stated stays unstated, so the fallback rule stays in charge.
    @Test func aReadLeavesAnUnstatedCountUnstated() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.read(upTo: precise))])
        #expect(try int("unreadCount", in: store) == nil)
    }

    @Test func aMarkAsUnreadIsKeptToTheMicrosecondAndCleared() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.markedUnread(at: precise))])
        #expect(try micros("markedUnreadAt", in: store) == 1_790_000_000_128_263)
        try store.apply([change(.markedUnread(at: nil))])
        #expect(try micros("markedUnreadAt", in: store) == nil)
    }

    @Test func followingIsSetAndUnset() throws {
        let store = try ChatStore.inMemory()
        try store.apply([change(.followed(true))])
        #expect(try bool("isFollowed", in: store) == true)
        try store.apply([change(.followed(false))])
        #expect(try bool("isFollowed", in: store) == false)
    }

    /// A topic id is unique only inside its conversation: the key is the pair.
    @Test func aThreadIsKeyedByItsConversationToo() throws {
        let store = try ChatStore.inMemory()
        let elsewhere = Conversation.ID("space/other")
        try store.apply([
            change(.followed(true)),
            .applyThreadChange(thread: topic, conversation: elsewhere, change: .followed(false))
        ])
        #expect(try bool("isFollowed", in: store) == true)
    }

    /// The conversation's flag is an UPDATE: nothing invents a conversation.
    @Test func theUnreadThreadsFlagInventsNoConversation() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setUnreadThreads(conversation: space, hasUnread: true)])
        #expect(try store.conversations().isEmpty)
    }
}
