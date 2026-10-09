import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `ThreadUnreadRule` (threads spec §4.2). Pure, so no store: the summary
/// read is checked against it in `StoreThreadReadTests`.
struct ThreadUnreadRuleTests {
    /// Off a millisecond, like every date in the thread tests.
    private let at = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func thread(
        followed: Bool? = nil, readPosition: Date? = nil, markedUnreadAt: Date? = nil, unreadCount: Int? = nil
    ) -> MessageThread {
        MessageThread(
            id: MessageThread.ID("topic:1"), conversationID: Conversation.ID("space/s"), replyCount: 3,
            isFollowed: followed, readPosition: readPosition, markedUnreadAt: markedUnreadAt,
            unreadCount: unreadCount
        )
    }

    private func isUnread(_ thread: MessageThread, newestReplyAt: Date?, participated: Bool = false) -> Bool {
        ThreadUnreadRule.isUnread(thread, newestReplyAt: newestReplyAt, participated: participated)
    }

    @Test func theStoredSettingDecidesAndPostingDecidesWhenNobodyHasSaid() {
        #expect(ThreadUnreadRule.isFollowed(thread(followed: true), participated: false))
        #expect(!ThreadUnreadRule.isFollowed(thread(followed: false), participated: true))
        #expect(ThreadUnreadRule.isFollowed(thread(), participated: true))
        #expect(!ThreadUnreadRule.isFollowed(thread(), participated: false))
    }

    /// A mark wins over everything, a zero count included.
    @Test func aThreadMarkedUnreadIsUnread() {
        #expect(isUnread(thread(markedUnreadAt: at, unreadCount: 0), newestReplyAt: nil))
    }

    /// The server's count decides both ways when there is one, over the fallback.
    @Test func theServersCountDecidesWhenThereIsOne() {
        #expect(isUnread(thread(unreadCount: 2), newestReplyAt: nil))
        let readByCount = thread(followed: true, readPosition: at, unreadCount: 0)
        #expect(!isUnread(readByCount, newestReplyAt: at.addingTimeInterval(60), participated: true))
    }

    /// The fallback: followed, and a reply strictly newer than the position,
    /// because equality is read (`findings.md` §42.2).
    @Test func withoutACountAFollowedThreadWithANewerReplyIsUnread() {
        let followed = thread(followed: true, readPosition: at)
        #expect(isUnread(followed, newestReplyAt: at.addingTimeInterval(0.000_001)))
        #expect(!isUnread(followed, newestReplyAt: at))
        #expect(!isUnread(followed, newestReplyAt: at.addingTimeInterval(-60)))
    }

    /// Following decides the fallback, posting standing in when nobody has said.
    @Test func withoutACountOnlyAFollowedThreadCanBeUnread() {
        let newer = at.addingTimeInterval(60)
        #expect(!isUnread(
            thread(followed: false, readPosition: at),
            newestReplyAt: newer,
            participated: true
        ))
        #expect(!isUnread(thread(readPosition: at), newestReplyAt: newer, participated: false))
        #expect(isUnread(thread(readPosition: at), newestReplyAt: newer, participated: true))
    }

    /// Ruling 2: nothing proves a reply is newer than a position nobody has
    /// stated, and with no reply there is nothing to be unread about.
    @Test func withoutACountAPositionAndAReplyAreBothNeeded() {
        #expect(!isUnread(thread(followed: true), newestReplyAt: at))
        #expect(!isUnread(thread(followed: true, readPosition: at), newestReplyAt: nil))
    }
}
