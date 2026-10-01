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

    /// The state is recorded, and a state that means "we are trying now"
    /// clears the last error along with it.
    ///
    /// The banner is one line and `lastError` wins it (`ChatWindow`'s
    /// `StatusStrip`), so a permanent error is a permanently hidden
    /// connection state: one failed send and the client could never say
    /// "Reconnecting, attempt 2…" again for the rest of the session.
    @Test func connectionStateIsRecordedSoTheUICanReadItFromTheStore() {
        let reduction = SyncReducer.reduce(
            .connectionStateChanged(.reconnecting(attempt: 2, issue: nil, detail: nil))
        )
        #expect(reduction.writes == [
            .setConnectionState(.reconnecting(attempt: 2, issue: nil, detail: nil)),
            .setLastError(nil)
        ])
        #expect(reduction.effects.isEmpty)
    }

    /// Connecting and connected clear it for the same reason reconnecting
    /// does: the newer claim is about now.
    @Test func aConnectionAttemptClearsTheLastError() {
        for state in [ConnectionState.connecting, .connected] {
            let reduction = SyncReducer.reduce(.connectionStateChanged(state))
            #expect(reduction.writes == [.setConnectionState(state), .setLastError(nil)])
        }
    }

    /// **Reversed from this test's first version**, which asserted `.unknown`
    /// cleared `lastError` the same way a connection attempt does, reading
    /// "degrade toward optimism" (spec §3.4) as licensing it. It does not:
    /// that rule governs how an *uninterpretable state is rendered*, not
    /// whether a diagnosis that already arrived gets discarded. An
    /// unrecognised state is absence of information about what a newer peer
    /// meant, not evidence of recovery - the same "assume less, never more"
    /// rule this repo applies everywhere else - so `.unknown` is grouped with
    /// `idle`/`disconnected` and leaves `lastError` alone. Concretely: a
    /// backend reports `.backendError(.notAuthenticated)`, then a newer server
    /// sends some interim state this build does not recognise - clearing here
    /// would wipe that diagnosis, and `ChatWindow.banner` (which gives
    /// `lastError` precedence over connection state) would silently downgrade
    /// "Signed out. Sign in again to keep syncing." - with its sign-in button
    /// - to "Connecting…".
    @Test func anUnrecognisedConnectionStateLeavesTheLastErrorInPlace() {
        let reduction = SyncReducer.reduce(.connectionStateChanged(.unknown("hibernating")))
        #expect(reduction.writes == [.setConnectionState(.unknown("hibernating"))])
    }

    /// **And disconnecting does not.** A backend reports why it stopped as
    /// `.backendError` and then reports the stop -
    /// `LocalBridgeBackend.channelStopped` emits that pair in that order - so
    /// clearing here would erase the diagnosis one event after it arrived and
    /// leave a bare "Disconnected." `idle` is the value a fresh process starts
    /// from rather than one a session moves into, and is left alone too.
    @Test func stoppingLeavesTheReasonItStoppedInPlace() {
        for state in [ConnectionState.disconnected(reason: "the channel closed", issue: nil), .idle] {
            let reduction = SyncReducer.reduce(.connectionStateChanged(state))
            #expect(reduction.writes == [.setConnectionState(state)])
        }
    }

    /// Both halves, the same shape `membersChangedFillsTheStoreAndTheMembership`
    /// checks below: who the local user is, *and* the record itself, so the
    /// name resolves out of the directory like anyone else's rather than
    /// needing a special case.
    ///
    /// Also supersedes a stale error - `get_self_user_status` succeeding is
    /// exactly the kind of forward progress `supersedingStaleError` exists
    /// to notice.
    @Test func selfIdentifiedRecordsWhoWeAreAndUpsertsTheRecord() {
        let me = Member(id: member, kind: .human, displayName: "One")
        let reduction = SyncReducer.reduce(.selfIdentified(me))
        #expect(reduction.writes == [
            .setLocalMember(member),
            .upsertMembers([me]),
            .setLastError(nil)
        ])
    }

    @Test func anErrorIsRecordedWholeRatherThanAsAString() {
        let reduction = SyncReducer.reduce(.backendError(.sessionExpired))
        // Kept typed: a client has to be able to tell "sign in again" from
        // "the network hiccuped", and a rendered string cannot be switched on.
        #expect(reduction.writes == [.setLastError(.sessionExpired)])
    }

    // MARK: - Conversations

    //
    // Every case below also carries a trailing `.setLastError(nil)` -
    // `supersedingStaleError`'s doc comment on `SyncReducer.reduce(_:)`
    // explains why forward progress like this supersedes a stale banner
    // rather than only a connection-state change doing so.

    @Test func theConversationListReplacesRatherThanMerges() {
        let list = [Conversation(id: conversation, kind: .space)]
        let reduction = SyncReducer.reduce(.conversationsChanged(list))
        // ChatEvent documents this as "the whole list, not a delta", so a
        // conversation that has gone must actually go.
        #expect(reduction.writes == [.replaceConversations(list), .setLastError(nil)])
    }

    @Test func oneConversationsSnapshotIsAnUpsert() {
        let updated = Conversation(id: conversation, kind: .space, title: "renamed")
        #expect(SyncReducer.reduce(.conversationUpdated(updated)).writes
            == [.upsertConversation(updated), .setLastError(nil)])
    }

    @Test func membersChangedFillsTheStoreAndTheMembership() {
        let people = [Member(id: member, kind: .human, displayName: "One")]
        let reduction = SyncReducer.reduce(
            .membersChanged(conversationID: conversation, members: people)
        )
        // Both halves are needed: the records themselves, and which
        // conversation they belong to in what order. A successful
        // `get_members` is also exactly the call the fix-round bug report
        // was about, so this is the case that matters most for the trailing
        // `.setLastError(nil)`.
        #expect(reduction.writes == [
            .upsertMembers(people),
            .setMembership(conversation: conversation, members: [member]),
            .setLastError(nil)
        ])
    }

    /// The directory half of `membersChanged` and nothing else. A sender
    /// resolved on demand is not a member of the conversation they wrote in
    /// (they may have left), so a membership write here would put a stranger
    /// in a group chat's derived title.
    @Test func membersResolvedFillsTheDirectoryAndTouchesNoMembership() {
        let people = [Member(id: member, kind: .human, displayName: "One")]
        #expect(SyncReducer.reduce(.membersResolved(people)).writes == [
            .upsertMembers(people),
            .setLastError(nil)
        ])
    }

    @Test func readStateCarriesTheCountRatherThanAskingTheStoreToCount() {
        let reduction = SyncReducer.reduce(
            .readStateChanged(conversationID: conversation, lastReadAt: at, unread: 3)
        )
        #expect(reduction.writes
            == [.setReadState(conversation: conversation, lastReadAt: at, unread: 3), .setLastError(nil)])
    }

    @Test func typingIsAWriteLikeAnythingElse() {
        let reduction = SyncReducer.reduce(
            .typingChanged(conversationID: conversation, member: member, isTyping: true)
        )
        #expect(reduction.writes
            == [
                .setTyping(conversation: conversation, member: member, isTyping: true),
                .setLastError(nil)
            ])
    }

    /// Both directions: a status lands, and `nil` clears it.
    @Test func aStatusLandsAndClearsOnTheMemberRecord() {
        let status = MemberStatus(emoji: "🌴", text: "On vacation")
        #expect(SyncReducer.reduce(.statusChanged(member: member, status: status)).writes
            == [.setStatus(member: member, status: status), .setLastError(nil)])
        #expect(SyncReducer.reduce(.statusChanged(member: member, status: nil)).writes
            == [.setStatus(member: member, status: nil), .setLastError(nil)])
    }

    @Test func presenceLandsOnTheMemberRecord() {
        #expect(SyncReducer.reduce(.presenceChanged(member: member, presence: .doNotDisturb)).writes
            == [.setPresence(member: member, presence: .doNotDisturb), .setLastError(nil)])
    }

    // MARK: - Messages

    @Test func aReceivedMessageIsAnUpsertAndMarksUnread() {
        let arrival = sample()
        #expect(SyncReducer.reduce(.messageReceived(arrival)).writes == [
            .upsertMessage(arrival),
            .markUnread(conversation: arrival.conversationID, sender: arrival.sender),
            .setLastError(nil)
        ])
    }

    /// Received and updated **no longer** reduce identically, and this pins
    /// the difference.
    ///
    /// They shared one case until `hasUnread` existed, on the reasoning that
    /// the store's job is to end up holding the message. That is still true of
    /// the upsert, but only an *arrival* can make a conversation unread: an
    /// edit to something already read must not raise the dot again. Note the
    /// store, not this, is what excludes the local user's own message.
    @Test func anUpdatedMessageIsAnUpsertAndDoesNotMarkUnread() {
        let edited = sample("corrected")
        #expect(SyncReducer.reduce(.messageUpdated(edited)).writes
            == [.upsertMessage(edited), .setLastError(nil)])
    }

    @Test func aDeletionIsATombstoneNotARemoval() {
        let reduction = SyncReducer.reduce(.messageDeleted(id: messageID, in: conversation))
        #expect(reduction.writes == [
            .markMessageDeleted(id: messageID, in: conversation),
            .setLastError(nil)
        ])
    }

    @Test func reactionsAreReplacedWholesale() {
        let reactions = [Reaction(emoji: "👍", count: 1, includesMe: true)]
        let reduction = SyncReducer.reduce(
            .reactionChanged(messageID: messageID, reactions: reactions)
        )
        #expect(reduction.writes
            == [.setReactions(messageID: messageID, reactions: reactions), .setLastError(nil)])
    }

    /// The fix-round regression test: a `.backendError` on its own does not
    /// clear itself (asserted by `anErrorIsRecordedWholeRatherThanAsAString`
    /// above), but the very next unrelated forward-progress event does -
    /// which is what stops a one-off `/api/` failure on an otherwise healthy
    /// channel from outliving its own relevance for the rest of the session.
    @Test func aLaterUnrelatedEventSupersedesAnEarlierBackendError() {
        let failed = SyncReducer
            .reduce(.backendError(.transport("the /api/ get_members call: transport error")))
        #expect(failed.writes == [.setLastError(.transport("the /api/ get_members call: transport error"))])

        let recovered = SyncReducer.reduce(.messageReceived(sample()))
        #expect(recovered.writes.contains(.setLastError(nil)))
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
        #expect(EventSamples.all.count == 17)
        for sample in EventSamples.all {
            let reduction = SyncReducer.reduce(sample.event)
            #expect(
                !reduction.writes.isEmpty || !reduction.effects.isEmpty || sample.producesNothing,
                "\(sample.name) reduced to nothing and did not say it meant to"
            )
        }
    }
}
