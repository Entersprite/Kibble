import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `NotificationPolicy` and the two reducer effects that feed it.
struct NotificationPolicyTests {
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let dm = Conversation.ID("dm/1")
    private let space = Conversation.ID("space/1")

    private func message(from sender: Member.ID, in conversation: Conversation.ID) -> Message {
        Message(
            id: Message.ID("m:1"),
            conversationID: conversation,
            threadID: MessageThread.ID("topic:1"),
            sender: sender,
            text: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - The policy

    private let loud = NotificationPolicy.Presentation(isPassive: false, playsSound: true, showsPreview: true)

    private func decide(
        _ message: Message, rule: ResolvedRule = .builtIn, me: Member.ID?, viewing: Conversation.ID? = nil,
        alreadyAnnounced: Bool = false, paused: Bool = false, mentionsMe: Bool = false
    ) -> NotificationPolicy.Decision {
        NotificationPolicy.decide(NotificationPolicy.Arrival(
            message: message, rule: rule, me: me, viewing: viewing,
            alreadyAnnounced: alreadyAnnounced, paused: paused, mentionsMe: mentionsMe
        ))
    }

    private func decideDelivery(_ delivery: Delivery, preview: Bool = true) -> NotificationPolicy.Decision {
        var rule = ResolvedRule.builtIn
        rule.delivery = delivery
        rule.showsPreview = preview
        return decide(message(from: alice, in: dm), rule: rule, me: me)
    }

    private func mentionsOnly(_ delivery: Delivery = .bannerAndSound) -> ResolvedRule {
        var rule = ResolvedRule.builtIn
        rule.delivery = delivery
        rule.notifyAbout = .mentions
        return rule
    }

    @Test func mentionsOnlyLetsThroughOnlyAMention() {
        let incoming = message(from: alice, in: dm)
        #expect(decide(incoming, rule: mentionsOnly(), me: me) == .suppress(.notMentioned))
        #expect(decide(incoming, rule: mentionsOnly(), me: me, mentionsMe: true) == .post(loud))
        // All messages is unaffected by whether it mentions me.
        #expect(decide(incoming, me: me) == .post(loud))
    }

    /// Nothing is Off, and it answers first: "why was I not notified?" says off.
    @Test func nothingWinsAndSaysOffEvenForAMention() {
        let incoming = message(from: alice, in: dm)
        #expect(decide(incoming, rule: mentionsOnly(.off), me: me) == .suppress(.off))
        #expect(decide(incoming, rule: mentionsOnly(.off), me: me, mentionsMe: true) == .suppress(.off))
    }

    @Test func aMentionNeverBeatsPauseOwnMessagesOrTheConversationOnScreen() {
        #expect(decide(
            message(from: alice, in: dm),
            rule: mentionsOnly(),
            me: me,
            paused: true,
            mentionsMe: true
        )
            == .suppress(.paused))
        #expect(decide(message(from: me, in: dm), rule: mentionsOnly(), me: me, mentionsMe: true)
            == .suppress(.ownMessage))
        #expect(decide(
            message(from: alice, in: dm),
            rule: mentionsOnly(),
            me: me,
            viewing: dm,
            mentionsMe: true
        )
            == .suppress(.onScreen))
    }

    @Test func someoneElsesMessageElsewhereIsPosted() {
        let decision = decide(message(from: alice, in: dm), me: me, viewing: space)
        #expect(decision == .post(loud))
    }

    /// The channel echoes this client's own sends back as arrivals.
    @Test func myOwnMessageIsNeverAnnounced() {
        let decision = decide(message(from: me, in: dm), me: me)
        #expect(decision == .suppress(.ownMessage))
    }

    /// Guessing here would announce the local user's own message.
    @Test func withNoIdentityYetNothingIsAnnounced() {
        let decision = decide(message(from: alice, in: dm), me: nil)
        #expect(decision == .suppress(.identityUnknown))
    }

    @Test func theConversationOnScreenIsNotAnnounced() {
        let decision = decide(message(from: alice, in: dm), me: me, viewing: dm)
        #expect(decision == .suppress(.onScreen))
    }

    @Test func aRedeliveredMessageIsNotAnnouncedTwice() {
        let decision = decide(message(from: alice, in: dm), me: me, alreadyAnnounced: true)
        #expect(decision == .suppress(.alreadyAnnounced))
    }

    @Test func eachDeliveryBecomesItsPresentation() {
        #expect(decideDelivery(.off) == .suppress(.off))
        #expect(decideDelivery(.notificationCenter) == .post(.init(
            isPassive: true,
            playsSound: false,
            showsPreview: true
        )))
        #expect(decideDelivery(.banner) == .post(.init(
            isPassive: false,
            playsSound: false,
            showsPreview: true
        )))
        #expect(decideDelivery(.bannerAndSound) == .post(loud))
    }

    @Test func previewIsCarriedThrough() {
        #expect(decideDelivery(.banner, preview: false) == .post(.init(
            isPassive: false,
            playsSound: false,
            showsPreview: false
        )))
    }

    /// Own messages and the screen are decided before the rule: a muted
    /// conversation's echo is still "own message", not "off".
    @Test func ownMessageIsDecidedBeforeDelivery() {
        var rule = ResolvedRule.builtIn
        rule.delivery = .off
        let decision = decide(message(from: me, in: dm), rule: rule, me: me)
        #expect(decision == .suppress(.ownMessage))
    }

    /// While paused nothing notifies - but a more specific reason still
    /// answers "why was I not notified?" first.
    @Test func whilePausedNothingIsPostedAndOwnMessagesStillSaySo() {
        let paused = decide(message(from: alice, in: dm), me: me, paused: true)
        #expect(paused == .suppress(.paused))
        let own = decide(message(from: me, in: dm), me: me, paused: true)
        #expect(own == .suppress(.ownMessage))
    }

    // MARK: - The reducer's side

    /// Only a live arrival announces. An edit must not raise a banner for
    /// something the user may already have read.
    @Test func anArrivalAnnouncesAndAnEditDoesNot() {
        let arrival = message(from: alice, in: dm)
        #expect(SyncReducer.reduce(.messageReceived(arrival)).effects == [.announceArrival(arrival)])
        #expect(SyncReducer.reduce(.messageUpdated(arrival)).effects.isEmpty)
    }

    /// Carries the position, so only covered notifications are withdrawn.
    @Test func aReadStateChangeWithdrawsUpToItsPosition() {
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let reduction = SyncReducer.reduce(.readStateChanged(conversationID: dm, lastReadAt: at, unread: 0))
        #expect(reduction.effects == [.withdrawAnnouncements(dm, upTo: at)])
    }
}
