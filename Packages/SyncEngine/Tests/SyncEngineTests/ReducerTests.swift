import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The reducer is pure, so these tests need no database, no async and no
/// backend. That is the point of separating it: the rules about what an event
/// means are checkable without any machinery at all.
struct ReducerTests {
    private let conversation = Conversation.ID("space:1")
    private let member = Member.ID("people/one")
    private let messageID = Message.ID("msg:1")
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    private func sample(_ text: String = "hello") -> Message {
        Message(
            id: messageID,
            conversationID: conversation,
            threadID: MessageThread.ID("topic:1"),
            sender: member,
            text: text,
            createdAt: at
        )
    }

    // MARK: - Connection and errors

    @Test func connectionStateIsRecordedSoTheUICanReadItFromTheStore() {
        let reduction = SyncReducer.reduce(.connectionStateChanged(.reconnecting(attempt: 2)))
        #expect(reduction.writes == [.setConnectionState(.reconnecting(attempt: 2))])
        #expect(reduction.effects.isEmpty)
    }

    @Test func anErrorIsRecordedWholeRatherThanAsAString() {
        let reduction = SyncReducer.reduce(.backendError(.sessionExpired))
        // Kept typed: a client has to be able to tell "sign in again" from
        // "the network hiccuped", and a rendered string cannot be switched on.
        #expect(reduction.writes == [.setLastError(.sessionExpired)])
    }

    // MARK: - Conversations

    @Test func theConversationListReplacesRatherThanMerges() {
        let list = [Conversation(id: conversation, kind: .space)]
        let reduction = SyncReducer.reduce(.conversationsChanged(list))
        // ChatEvent documents this as "the whole list, not a delta", so a
        // conversation that has gone must actually go.
        #expect(reduction.writes == [.replaceConversations(list)])
    }

    @Test func oneConversationsSnapshotIsAnUpsert() {
        let updated = Conversation(id: conversation, kind: .space, title: "renamed")
        #expect(SyncReducer.reduce(.conversationUpdated(updated)).writes
            == [.upsertConversation(updated)])
    }

    @Test func membersChangedFillsTheStoreAndTheMembership() {
        let people = [Member(id: member, kind: .human, displayName: "One")]
        let reduction = SyncReducer.reduce(
            .membersChanged(conversationID: conversation, members: people)
        )
        // Both halves are needed: the records themselves, and which
        // conversation they belong to in what order.
        #expect(reduction.writes == [
            .upsertMembers(people),
            .setMembership(conversation: conversation, members: [member])
        ])
    }

    @Test func readStateCarriesTheCountRatherThanAskingTheStoreToCount() {
        let reduction = SyncReducer.reduce(
            .readStateChanged(conversationID: conversation, lastReadAt: at, unread: 3)
        )
        #expect(reduction.writes
            == [.setReadState(conversation: conversation, lastReadAt: at, unread: 3)])
    }

    @Test func typingIsAWriteLikeAnythingElse() {
        let reduction = SyncReducer.reduce(
            .typingChanged(conversationID: conversation, member: member, isTyping: true)
        )
        #expect(reduction.writes
            == [.setTyping(conversation: conversation, member: member, isTyping: true)])
    }

    @Test func presenceLandsOnTheMemberRecord() {
        #expect(SyncReducer.reduce(.presenceChanged(member: member, presence: .doNotDisturb)).writes
            == [.setPresence(member: member, presence: .doNotDisturb)])
    }

    // MARK: - Messages

    @Test func aReceivedMessageIsAnUpsert() {
        #expect(SyncReducer.reduce(.messageReceived(sample())).writes == [.upsertMessage(sample())])
    }

    /// Received and updated reduce identically, on purpose: the store's job is
    /// to end up with the message, and an upsert already says that.
    @Test func anUpdatedMessageIsTheSameUpsert() {
        let edited = sample("corrected")
        #expect(SyncReducer.reduce(.messageUpdated(edited)).writes == [.upsertMessage(edited)])
    }

    @Test func aDeletionIsATombstoneNotARemoval() {
        let reduction = SyncReducer.reduce(.messageDeleted(id: messageID, in: conversation))
        #expect(reduction.writes == [.markMessageDeleted(id: messageID, in: conversation)])
    }

    @Test func reactionsAreReplacedWholesale() {
        let reactions = [Reaction(emoji: "👍", count: 1, includesMe: true)]
        let reduction = SyncReducer.reduce(
            .reactionChanged(messageID: messageID, reactions: reactions)
        )
        #expect(reduction.writes == [.setReactions(messageID: messageID, reactions: reactions)])
    }

    // MARK: - Gaps

    /// The one event a pure function cannot honour: "reconcile from scratch"
    /// means go and fetch.
    @Test func aWholeWorldGapAsksForTheConversationListAndWritesNothing() {
        let reduction = SyncReducer.reduce(.gap(scope: .everything, reason: "buffer overflowed"))
        #expect(reduction.writes.isEmpty)
        #expect(reduction.effects == [.reloadConversations])
    }

    @Test func aConversationGapAsksForThatConversationsMessages() {
        let reduction = SyncReducer.reduce(
            .gap(scope: .conversation(conversation), reason: "catch-up aborted")
        )
        #expect(reduction.writes.isEmpty)
        #expect(reduction.effects == [.reloadMessages(conversation)])
    }

    /// Deliberately nothing. Forward compatibility means a client built before
    /// a feature ignores it rather than failing - and a test says so, to stop
    /// someone "fixing" it later.
    @Test func anUnknownEventProducesNothingAtAll() {
        let reduction = SyncReducer.reduce(.unknown(type: "huddleStarted", payload: .object([:])))
        #expect(reduction.writes.isEmpty)
        #expect(reduction.effects.isEmpty)
    }

    /// Hand-written for the reason ChatKit's frame coverage lists give: a
    /// derived list would start passing the moment a case was added, which is
    /// the one moment it must fail.
    @Test func everyEventCaseIsCovered() {
        #expect(EventSamples.all.count == 14)
        for sample in EventSamples.all {
            let reduction = SyncReducer.reduce(sample.event)
            #expect(
                !reduction.writes.isEmpty || !reduction.effects.isEmpty || sample.producesNothing,
                "\(sample.name) reduced to nothing and did not say it meant to"
            )
        }
    }
}
