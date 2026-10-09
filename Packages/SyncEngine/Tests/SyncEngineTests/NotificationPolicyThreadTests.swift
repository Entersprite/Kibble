import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `NotificationPolicy` for replies (threads spec §4.3): a reply is announced
/// only when its thread is followed or it mentions you, and it is on screen
/// only when its thread's panel is.
struct NotificationPolicyThreadTests {
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let space = Conversation.ID("space/1")
    private let loud = NotificationPolicy.Presentation(isPassive: false, playsSound: true, showsPreview: true)
    private let followed = NotificationPolicy.ThreadContext(isFollowed: true, isOnScreen: false)
    private let unfollowed = NotificationPolicy.ThreadContext(isFollowed: false, isOnScreen: false)

    private func message(isReply: Bool) -> Message {
        Message(
            id: Message.ID("m:1"), conversationID: space, threadID: MessageThread.ID("topic:1"),
            sender: alice,
            text: "on it", createdAt: Date(timeIntervalSince1970: 1_790_000_000), isReply: isReply
        )
    }

    private func decide(
        _ message: Message, thread: NotificationPolicy.ThreadContext?, rule: ResolvedRule = .builtIn,
        viewing: Conversation.ID? = nil, mentionsMe: Bool = false
    ) -> NotificationPolicy.Decision {
        NotificationPolicy.decide(NotificationPolicy.Arrival(
            message: message, rule: rule, me: me, viewing: viewing,
            alreadyAnnounced: false, paused: false, mentionsMe: mentionsMe, thread: thread
        ))
    }

    @Test func aReplyInAFollowedThreadIsAnnounced() {
        #expect(decide(message(isReply: true), thread: followed) == .post(loud))
    }

    /// The suppression this task adds. Seen red with the guard deleted (Step 5).
    @Test func aReplyInAThreadYouDoNotFollowIsNotAnnounced() {
        #expect(decide(message(isReply: true), thread: unfollowed) == .suppress(.threadNotFollowed))
    }

    @Test func aReplyThatMentionsYouIsAnnouncedWhetherOrNotYouFollow() {
        #expect(decide(message(isReply: true), thread: unfollowed, mentionsMe: true) == .post(loud))
    }

    /// Ruling 11: a caller that knows nothing about the thread lets only a
    /// mention through.
    @Test func aReplyWithNoThreadContextCountsAsNotFollowed() {
        #expect(decide(message(isReply: true), thread: nil) == .suppress(.threadNotFollowed))
        #expect(decide(message(isReply: true), thread: nil, mentionsMe: true) == .post(loud))
    }

    /// On screen for a reply is its thread's panel, not its conversation.
    @Test func aReplyIsOnScreenOnlyWhenItsThreadsPanelIs() {
        let showing = NotificationPolicy.ThreadContext(isFollowed: true, isOnScreen: true)
        #expect(decide(message(isReply: true), thread: showing) == .suppress(.onScreen))
        #expect(decide(message(isReply: true), thread: followed, viewing: space) == .post(loud))
    }

    /// A top-level message ignores a thread context, whatever it says.
    @Test func aTopLevelMessageIgnoresAThreadContext() {
        let showing = NotificationPolicy.ThreadContext(isFollowed: false, isOnScreen: true)
        #expect(decide(message(isReply: false), thread: showing) == .post(loud))
        #expect(decide(message(isReply: false), thread: unfollowed, viewing: space) == .suppress(.onScreen))
    }

    /// Ruling 12: Off answers first, as it does for a mention, and a followed
    /// reply in a mentions-only conversation still needs the mention.
    @Test func theConversationsRuleStillAppliesAndOffAnswersFirst() {
        var off = ResolvedRule.builtIn
        off.delivery = .off
        #expect(decide(message(isReply: true), thread: unfollowed, rule: off) == .suppress(.off))
        var mentionsOnly = ResolvedRule.builtIn
        mentionsOnly.notifyAbout = .mentions
        #expect(decide(message(isReply: true), thread: followed, rule: mentionsOnly) ==
            .suppress(.notMentioned))
        #expect(decide(message(isReply: true), thread: unfollowed, rule: mentionsOnly)
            == .suppress(.threadNotFollowed))
    }
}
