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

    private func decide(_ delivery: Delivery, preview: Bool = true) -> NotificationPolicy.Decision {
        var rule = ResolvedRule.builtIn
        rule.delivery = delivery
        rule.showsPreview = preview
        return NotificationPolicy.decide(
            message(from: alice, in: dm),
            rule: rule,
            me: me,
            viewing: nil,
            alreadyAnnounced: false, paused: false
        )
    }

    @Test func someoneElsesMessageElsewhereIsPosted() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), rule: .builtIn, me: me, viewing: space, alreadyAnnounced: false,
            paused: false
        )
        #expect(decision == .post(loud))
    }

    /// The channel echoes this client's own sends back as arrivals.
    @Test func myOwnMessageIsNeverAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: me, in: dm), rule: .builtIn, me: me, viewing: nil, alreadyAnnounced: false,
            paused: false
        )
        #expect(decision == .suppress(.ownMessage))
    }

    /// Guessing here would announce the local user's own message.
    @Test func withNoIdentityYetNothingIsAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), rule: .builtIn, me: nil, viewing: nil, alreadyAnnounced: false,
            paused: false
        )
        #expect(decision == .suppress(.identityUnknown))
    }

    @Test func theConversationOnScreenIsNotAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), rule: .builtIn, me: me, viewing: dm, alreadyAnnounced: false,
            paused: false
        )
        #expect(decision == .suppress(.onScreen))
    }

    @Test func aRedeliveredMessageIsNotAnnouncedTwice() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), rule: .builtIn, me: me, viewing: nil, alreadyAnnounced: true,
            paused: false
        )
        #expect(decision == .suppress(.alreadyAnnounced))
    }

    @Test func eachDeliveryBecomesItsPresentation() {
        #expect(decide(.off) == .suppress(.off))
        #expect(decide(.notificationCenter) == .post(.init(
            isPassive: true,
            playsSound: false,
            showsPreview: true
        )))
        #expect(decide(.banner) == .post(.init(isPassive: false, playsSound: false, showsPreview: true)))
        #expect(decide(.bannerAndSound) == .post(loud))
    }

    @Test func previewIsCarriedThrough() {
        #expect(decide(.banner, preview: false) == .post(.init(
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
        let decision = NotificationPolicy.decide(
            message(from: me, in: dm),
            rule: rule,
            me: me,
            viewing: nil,
            alreadyAnnounced: false, paused: false
        )
        #expect(decision == .suppress(.ownMessage))
    }

    /// While paused nothing notifies - but a more specific reason still
    /// answers "why was I not notified?" first.
    @Test func whilePausedNothingIsPostedAndOwnMessagesStillSaySo() {
        let paused = NotificationPolicy.decide(
            message(from: alice, in: dm), rule: .builtIn, me: me, viewing: nil,
            alreadyAnnounced: false, paused: true
        )
        #expect(paused == .suppress(.paused))
        let own = NotificationPolicy.decide(
            message(from: me, in: dm), rule: .builtIn, me: me, viewing: nil,
            alreadyAnnounced: false, paused: true
        )
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
