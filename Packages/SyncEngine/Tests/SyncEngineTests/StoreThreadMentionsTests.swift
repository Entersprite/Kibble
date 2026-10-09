import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Mentions in replies (threads spec §4.1, §4.3): the Mentions reads keep
/// replies, and a reply's mention is read by its thread's position when the
/// store has one, else by its conversation's. The list and the badge agree.
@Suite(.timeLimit(.minutes(1)))
struct StoreThreadMentionsTests {
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let space = Conversation.ID("space/s")
    private let topic = MessageThread.ID("topic:1")
    /// Off a millisecond: the boundary must hold through REAL columns.
    private let position = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func mention(isReply: Bool) -> Message {
        Message(
            id: Message.ID(isReply ? "m:reply" : "m:top"), conversationID: space, threadID: topic,
            sender: alice, text: "@Me hi", createdAt: position,
            mentions: [Mention(target: .user(me), start: 0, length: 3)], isReply: isReply
        )
    }

    private func store(conversationRead: Date?, threadRead: Date?, isReply: Bool = true) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        var writes: [StoreWrite] = [
            .setLocalMember(me),
            .replaceConversations([Conversation(id: space, kind: .space, readPosition: conversationRead)]),
            .upsertMessage(mention(isReply: isReply))
        ]
        if let threadRead {
            writes.append(.applyThreadChange(
                thread: topic, conversation: space, change: .read(upTo: threadRead)
            ))
        }
        try store.apply(writes)
        return store
    }

    /// The list's answer and the badge's, read together.
    private func unread(_ store: ChatStore) throws -> (listed: Bool?, counted: Int) {
        try (store.mentionsOfMe().first?.isUnread, store.unreadMentionCount())
    }

    @Test func aMentionInAReplyIsListed() throws {
        let store = try store(conversationRead: nil, threadRead: nil)
        #expect(try store.mentionsOfMe().map(\.message.id.rawValue) == ["m:reply"])
    }

    /// The thread's position decides, equality included (`findings.md`
    /// §42.2), though the conversation has never been read.
    @Test func aRepliesMentionIsReadByItsThreadsPosition() throws {
        let state = try unread(store(conversationRead: nil, threadRead: position))
        #expect(state.listed == false)
        #expect(state.counted == 0)
    }

    /// And unread by it, though the conversation's position is later: that
    /// position follows top-level messages, which never cover a reply.
    @Test func aRepliesMentionIsUnreadByItsThreadsPositionPastTheConversations() throws {
        let state = try unread(store(
            conversationRead: position.addingTimeInterval(60), threadRead: position.addingTimeInterval(-60)
        ))
        #expect(state.listed == true)
        #expect(state.counted == 1)
    }

    @Test func withoutAThreadPositionTheConversationsDecides() throws {
        let state = try unread(store(conversationRead: position.addingTimeInterval(60), threadRead: nil))
        #expect(state.listed == false)
        #expect(state.counted == 0)
    }

    /// A top-level message is read by its conversation's position, whatever
    /// its topic's row says.
    @Test func aTopLevelMentionIgnoresItsThreadsPosition() throws {
        let state = try unread(store(
            conversationRead: nil, threadRead: position.addingTimeInterval(60), isReply: false
        ))
        #expect(state.listed == true)
        #expect(state.counted == 1)
    }
}
