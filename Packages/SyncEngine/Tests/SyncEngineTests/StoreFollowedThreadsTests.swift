import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The Threads list and its badge as store reads (threads spec §4.1, §5.3):
/// threads the server says you follow, newest activity first (ruling 10).
@Suite(.timeLimit(.minutes(1)))
struct StoreFollowedThreadsTests {
    private let space = Conversation.ID("space/s")
    private let dm = Conversation.ID("dm/d")
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let start = Date(timeIntervalSince1970: 1_790_000_000.128263)

    /// Thread `thread` in `conversation`: its first message at `minute`, from
    /// `rootSender` or Alice, and one reply from Alice at `replyMinute`.
    private func thread(
        _ thread: String, in conversation: Conversation.ID, minute: Int, replyMinute: Int,
        rootSender: Member.ID? = nil
    ) -> [StoreWrite] {
        let root = Message(
            id: Message.ID("m:\(thread)"), conversationID: conversation,
            threadID: MessageThread.ID(thread), sender: rootSender ?? alice, text: "hi",
            createdAt: start.addingTimeInterval(TimeInterval(minute * 60))
        )
        var reply = root
        reply.id = Message.ID("m:\(thread)-reply")
        reply.sender = alice
        reply.createdAt = start.addingTimeInterval(TimeInterval(replyMinute * 60))
        reply.isReply = true
        return [.upsertMessage(root), .upsertMessage(reply)]
    }

    private func change(
        _ thread: String, in conversation: Conversation.ID, _ change: ThreadChange
    ) -> StoreWrite {
        .applyThreadChange(thread: MessageThread.ID(thread), conversation: conversation, change: change)
    }

    private func store(_ writes: [StoreWrite]) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        let listed = [Conversation(id: space, kind: .space), Conversation(id: dm, kind: .directMessage)]
        let base: [StoreWrite] = [.setLocalMember(me), .replaceConversations(listed)]
        try store.apply(base + writes)
        return store
    }

    /// Two followed and one unfollowed, in two conversations.
    private func threeThreads() throws -> ChatStore {
        try store(
            thread("topic:a", in: space, minute: 0, replyMinute: 10)
                + thread("topic:b", in: dm, minute: 5, replyMinute: 20)
                + thread("topic:c", in: space, minute: 1, replyMinute: 30)
                + [
                    change("topic:a", in: space, .followed(true)),
                    change("topic:b", in: dm, .followed(true)),
                    change("topic:c", in: space, .followed(false))
                ]
        )
    }

    @Test func followedThreadsAreListedNewestActivityFirstWithTheirFirstMessage() throws {
        let listed = try threeThreads().followedThreads(limit: 10)
        #expect(listed.map(\.root.id.rawValue) == ["m:topic:b", "m:topic:a"])
        #expect(listed.map(\.thread.id.rawValue) == ["topic:b", "topic:a"])
        #expect(listed.first?.thread.replyCount == 2)
        #expect(listed.first?.root.isReply == false)
    }

    /// A topic id is unique only inside its conversation, and the list reads
    /// every followed thread at once: the same id in two conversations is two
    /// threads, each with its own count.
    @Test func theSameTopicIdInTwoConversationsIsTwoThreads() throws {
        func message(_ id: String, in conversation: Conversation.ID, minute: Int) -> Message {
            Message(
                id: Message.ID(id), conversationID: conversation, threadID: MessageThread.ID("topic:same"),
                sender: alice, text: "hi", createdAt: start.addingTimeInterval(TimeInterval(minute * 60)),
                isReply: minute > 0
            )
        }
        let store = try store([
            .upsertMessage(message("m:s-root", in: space, minute: 0)),
            .upsertMessage(message("m:s-1", in: space, minute: 1)),
            .upsertMessage(message("m:s-2", in: space, minute: 2)),
            .upsertMessage(message("m:d-root", in: dm, minute: 0)),
            .upsertMessage(message("m:d-1", in: dm, minute: 5)),
            change("topic:same", in: space, .followed(true)),
            change("topic:same", in: dm, .followed(true))
        ])
        let listed = try store.followedThreads(limit: 10)
        #expect(listed.map(\.thread.conversationID) == [dm, space])
        #expect(listed.map(\.thread.replyCount) == [2, 3])
        #expect(listed.map(\.root.id.rawValue) == ["m:d-root", "m:s-root"])
    }

    @Test func theLimitKeepsTheNewest() throws {
        #expect(try threeThreads().followedThreads(limit: 1).map(\.thread.id.rawValue) == ["topic:b"])
    }

    /// The list needs a first message to show and a conversation to name.
    @Test func aThreadWithoutItsFirstMessageOrItsConversationIsLeftOut() throws {
        let gone = Conversation.ID("space/gone")
        let orphan = Array(thread("topic:orphan", in: space, minute: 0, replyMinute: 1).dropFirst())
        let store = try store(
            orphan + thread("topic:gone", in: gone, minute: 0, replyMinute: 1) + [
                change("topic:orphan", in: space, .followed(true)),
                change("topic:gone", in: gone, .followed(true))
            ]
        )
        #expect(try store.followedThreads(limit: 10).isEmpty)
    }

    /// The list is the server's word: posting makes a thread followed for
    /// notifications (ruling 1), not for the list.
    @Test func aThreadYouOnlyPostedInIsNotListed() throws {
        let store = try store(thread("topic:mine", in: space, minute: 0, replyMinute: 1, rootSender: me))
        #expect(try store.followedThreads(limit: 10).isEmpty)
        #expect(try store.thread(MessageThread.ID("topic:mine"), in: space)?.isFollowed == true)
    }

    /// Every unread followed thread the list would show, not only the
    /// `limit` it shows, and the count moves back when one is read.
    @Test func theBadgeCountsUnreadFollowedThreadsBeyondTheLimitAndMovesBack() throws {
        let store = try store(
            thread("topic:a", in: space, minute: 0, replyMinute: 10)
                + thread("topic:b", in: dm, minute: 5, replyMinute: 20)
                + [
                    change("topic:a", in: space, .followed(true)),
                    change("topic:a", in: space, .counted(messages: 2, unread: 1)),
                    change("topic:b", in: dm, .followed(true)),
                    change("topic:b", in: dm, .markedUnread(at: start))
                ]
        )
        #expect(try store.followedThreads(limit: 1).count == 1)
        #expect(try store.unreadThreadCount() == 2)
        try store.apply([change("topic:b", in: dm, .markedUnread(at: nil))])
        #expect(try store.unreadThreadCount() == 1)
    }

    @Test func theBadgeIsObserved() async throws {
        let store = try store(
            thread("topic:a", in: space, minute: 0, replyMinute: 10) + [
                change("topic:a", in: space, .followed(true)),
                change("topic:a", in: space, .counted(messages: 2, unread: 1))
            ]
        )
        var iterator = store.observeUnreadThreadCount().makeAsyncIterator()
        #expect(try await iterator.next() == 1)
        try store.apply([change("topic:a", in: space, .counted(messages: 2, unread: 0))])
        #expect(try await iterator.next() == 0)
    }
}
