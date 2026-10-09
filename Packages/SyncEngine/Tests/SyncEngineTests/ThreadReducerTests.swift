import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// What a reply's arrival and a thread's events mean for the store (threads
/// spec §4.1, §4.3). Pure: no database.
struct ThreadReducerTests {
    private let space = Conversation.ID("space/s")
    private let topic = MessageThread.ID("topic:1")
    private let alice = Member.ID("users/alice")
    private let at = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func reply() -> Message {
        Message(
            id: Message.ID("m:reply"), conversationID: space, threadID: topic, sender: alice,
            text: "on it", createdAt: at, isReply: true
        )
    }

    /// A reply is stored and announced, and marks nothing unread: the
    /// conversation's unread state counts top-level messages (spec §4.3).
    /// Seen red with the guard deleted (Step 15).
    @Test func aReplyIsStoredAndAnnouncedAndMarksNothingUnread() {
        let reduction = SyncReducer.reduce(.messageReceived(reply()))
        #expect(reduction.writes == [.upsertMessageKeepingReactions(reply()), .setLastError(nil)])
        #expect(reduction.effects == [.announceArrival(reply())])
    }

    @Test func eachThreadChangeIsAppliedToItsThread() {
        let changes: [ThreadChange] = [
            .counted(messages: 5, unread: 1), .counted(messages: 5, unread: nil), .read(upTo: at),
            .markedUnread(at: at), .markedUnread(at: nil), .followed(true), .followed(false)
        ]
        for change in changes {
            let event = ChatEvent.threadChanged(threadID: topic, conversationID: space, change: change)
            #expect(SyncReducer.reduce(event).writes == [
                .applyThreadChange(thread: topic, conversation: space, change: change),
                .setLastError(nil)
            ])
        }
    }

    /// Forward compatibility: a change this build does not know writes
    /// nothing to the thread. The event still proves the channel works.
    @Test func anUnknownThreadChangeWritesNothingToTheThread() {
        let change = ThreadChange.unknown(type: "pinned", payload: .object([:]))
        let event = ChatEvent.threadChanged(threadID: topic, conversationID: space, change: change)
        let reduction = SyncReducer.reduce(event)
        #expect(reduction.writes == [.setLastError(nil)])
        #expect(reduction.effects.isEmpty)
    }

    /// Push 53, both ways.
    @Test func theConversationsUnreadThreadsFlagMovesBothWays() {
        for hasUnread in [true, false] {
            let event = ChatEvent.unreadThreadsChanged(conversationID: space, hasUnread: hasUnread)
            #expect(SyncReducer.reduce(event).writes == [
                .setUnreadThreads(conversation: space, hasUnread: hasUnread),
                .setLastError(nil)
            ])
        }
    }
}
