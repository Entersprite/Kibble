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

    @Test func someoneElsesMessageElsewhereIsPosted() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), me: me, viewing: space, alreadyAnnounced: false
        )
        #expect(decision == .post)
    }

    /// The channel echoes this client's own sends back as arrivals.
    @Test func myOwnMessageIsNeverAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: me, in: dm), me: me, viewing: nil, alreadyAnnounced: false
        )
        #expect(decision == .suppress(.ownMessage))
    }

    /// Guessing here would announce the local user's own message.
    @Test func withNoIdentityYetNothingIsAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), me: nil, viewing: nil, alreadyAnnounced: false
        )
        #expect(decision == .suppress(.identityUnknown))
    }

    @Test func theConversationOnScreenIsNotAnnounced() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), me: me, viewing: dm, alreadyAnnounced: false
        )
        #expect(decision == .suppress(.onScreen))
    }

    @Test func aRedeliveredMessageIsNotAnnouncedTwice() {
        let decision = NotificationPolicy.decide(
            message(from: alice, in: dm), me: me, viewing: nil, alreadyAnnounced: true
        )
        #expect(decision == .suppress(.alreadyAnnounced))
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
