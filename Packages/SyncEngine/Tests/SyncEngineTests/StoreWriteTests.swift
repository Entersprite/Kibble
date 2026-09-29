import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Every `StoreWrite`, applied and read back. An in-memory database, so these
/// are as fast as the reducer tests and need no temporary files.
struct StoreWriteTests {
    private let space = Conversation.ID("space:1")
    private let dm = Conversation.ID("dm:1")
    private let alice = Member.ID("people/alice")
    private let bob = Member.ID("people/bob")
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    private func store() throws -> ChatStore {
        try ChatStore.inMemory()
    }

    private func conversation(
        _ id: Conversation.ID,
        title: String? = nil,
        activity: Date? = nil,
        members: [Member.ID] = []
    ) -> Conversation {
        Conversation(
            id: id,
            kind: id == dm ? .directMessage : .space,
            title: title,
            lastActivity: activity,
            members: members
        )
    }

    private func message(_ id: String, in conversation: Conversation.ID, at when: Date) -> Message {
        Message(
            id: Message.ID(id),
            conversationID: conversation,
            threadID: MessageThread.ID("topic:1"),
            sender: alice,
            text: "hello",
            createdAt: when
        )
    }

    // MARK: - Conversations

    @Test func replacingTheListInsertsWhatIsThereAndRemovesWhatIsNot() throws {
        let store = try store()
        try store.apply([.replaceConversations([conversation(space), conversation(dm)])])
        #expect(try store.conversations().count == 2)

        try store.apply([.replaceConversations([conversation(space)])])
        #expect(try store.conversations().map(\.id) == [space])
    }

    /// Deliberate: messages survive their conversation leaving the list.
    ///
    /// A conversation can vanish from a list for reasons that reverse - hidden,
    /// or a bad reconcile - and history is expensive to re-fetch. Orphaned rows
    /// are invisible because nothing renders a conversation that is not there,
    /// and they come back for free if it returns.
    @Test func removingAConversationKeepsItsMessages() throws {
        let store = try store()
        try store.apply([
            .replaceConversations([conversation(space)]),
            .upsertMessage(message("msg:1", in: space, at: at))
        ])

        try store.apply([.replaceConversations([])])

        #expect(try store.conversations().isEmpty)
        #expect(try store.messages(in: space).count == 1)
    }

    @Test func upsertingAConversationRoundTripsEveryField() throws {
        let store = try store()
        var original = conversation(space, title: "price-engine", activity: at)
        original.unreadCount = 4
        original.isMuted = true
        original.notificationLevel = .less
        original.isThreaded = true
        original.avatarURL = URL(string: "https://example.invalid/a.png")
        original.members = [alice, bob]
        original.readPosition = Date(timeIntervalSince1970: 1_790_000_000.128263)

        try store.apply([.upsertConversation(original)])

        #expect(try store.conversations() == [original])
    }

    /// An open enum's unknown case has to survive the round trip, or a
    /// conversation type this build does not know becomes a conversation type
    /// it gets wrong.
    @Test func anUnknownConversationKindSurvivesStorage() throws {
        let store = try store()
        let meet = Conversation(id: Conversation.ID("space:meet"), kind: .unknown("meetCall"))
        try store.apply([.upsertConversation(meet)])
        #expect(try store.conversations().first?.kind == .unknown("meetCall"))
    }

    @Test func aConversationWithNoTitleIsDistinctFromOneWithAnEmptyTitle() throws {
        let store = try store()
        try store.apply([
            .upsertConversation(conversation(dm, title: nil)),
            .upsertConversation(conversation(space, title: ""))
        ])
        let stored = try store.conversations()
        #expect(stored.first { $0.id == dm }?.title == nil)
        #expect(stored.first { $0.id == space }?.title == "")
    }

    // MARK: - Members

    @Test func membersAndMembershipAreStoredSeparately() throws {
        let store = try store()
        let people = [
            Member(id: alice, kind: .human, displayName: "Alice", email: "a@example.invalid"),
            Member(id: bob, kind: .app)
        ]
        try store.apply([
            .upsertConversation(conversation(space)),
            .upsertMembers(people),
            .setMembership(conversation: space, members: [bob, alice])
        ])

        #expect(try store.members() == people)
        // Order is the conversation's, not the table's.
        #expect(try store.conversations().first?.members == [bob, alice])
    }

    @Test func settingMembershipReplacesRatherThanAdding() throws {
        let store = try store()
        try store.apply([
            .upsertConversation(conversation(space)),
            .setMembership(conversation: space, members: [alice, bob]),
            .setMembership(conversation: space, members: [alice])
        ])
        #expect(try store.conversations().first?.members == [alice])
    }

    @Test func presenceLandsOnTheMemberRecord() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .doNotDisturb)
        ])
        #expect(try store.members().first?.presence == .doNotDisturb)
    }

    /// Presence for someone the store has never heard of must not invent a
    /// member row with no name - a half-member renders as a blank in the UI.
    @Test func presenceForAnUnknownMemberIsDropped() throws {
        let store = try store()
        try store.apply([.setPresence(member: alice, presence: .active)])
        #expect(try store.members().isEmpty)
    }

    // MARK: - Messages

    @Test func aMessageRoundTripsIncludingItsJSONColumns() throws {
        let store = try store()
        var original = message("msg:1", in: space, at: at)
        original.editedAt = at.addingTimeInterval(60)
        original.localID = "draft-1"
        original.reactions = [Reaction(emoji: "👍", count: 2, includesMe: true)]
        original.attachments = [
            Attachment(id: "att:1", name: "spec.pdf", contentType: "application/pdf", byteSize: 12)
        ]

        try store.apply([.upsertMessage(original)])

        #expect(try store.messages(in: space) == [original])
    }

    @Test func messagesComeBackOldestFirst() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message("msg:2", in: space, at: at.addingTimeInterval(60))),
            .upsertMessage(message("msg:1", in: space, at: at)),
            .upsertMessage(message("msg:3", in: space, at: at.addingTimeInterval(120)))
        ])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["msg:1", "msg:2", "msg:3"])
    }

    @Test func upsertingTheSameMessageTwiceKeepsOneRow() throws {
        let store = try store()
        try store.apply([.upsertMessage(message("msg:1", in: space, at: at))])
        var edited = message("msg:1", in: space, at: at)
        edited.text = "corrected"
        try store.apply([.upsertMessage(edited)])

        #expect(try store.messages(in: space).map(\.text) == ["corrected"])
    }

    @Test func aDeletedMessageKeepsItsPlace() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message("msg:1", in: space, at: at)),
            .upsertMessage(message("msg:2", in: space, at: at.addingTimeInterval(60))),
            .markMessageDeleted(id: Message.ID("msg:1"), in: space)
        ])

        let stored = try store.messages(in: space)
        #expect(stored.map(\.id.rawValue) == ["msg:1", "msg:2"])
        #expect(stored.first?.isDeleted == true)
    }

    /// The opposite of a tombstone, and it has to be. A send that threw was
    /// never posted, so a row that keeps its place and renders as "deleted"
    /// would still be claiming something happened. Nothing did.
    ///
    /// Keyed on the id the client invented, so the message beside it is
    /// untouched - and so is the *delivered* copy of this very message, which
    /// carries the same `localID` and a different id.
    @Test func removingAMessageByIDLeavesNoRowBehind() throws {
        let store = try store()
        var ours = message("local/l-1", in: space, at: at)
        ours.localID = "l-1"
        try store.apply([
            .upsertMessage(ours),
            .upsertMessage(message("msg:2", in: space, at: at.addingTimeInterval(60)))
        ])
        #expect(try store.messages(in: space).count == 2)

        try store.apply([.removeMessage(id: Message.ID("local/l-1"))])
        #expect(try store.messages(in: space).map(\.id.rawValue) == ["msg:2"])
    }

    @Test func reactionsAreReplacedWholesale() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message("msg:1", in: space, at: at)),
            .setReactions(
                messageID: Message.ID("msg:1"),
                reactions: [Reaction(emoji: "👍", count: 1, includesMe: true)]
            ),
            .setReactions(
                messageID: Message.ID("msg:1"),
                reactions: [Reaction(emoji: "🎉", count: 2, includesMe: false)]
            )
        ])
        #expect(try store.messages(in: space).first?.reactions
            == [Reaction(emoji: "🎉", count: 2, includesMe: false)])
    }

    // MARK: - Read state, typing, session

    @Test func readStateSetsTheCountAndTheWatermark() throws {
        let store = try store()
        try store.apply([
            .upsertConversation(conversation(space)),
            .setReadState(conversation: space, lastReadAt: at, unread: 7)
        ])
        #expect(try store.conversations().first?.unreadCount == 7)
        #expect(try store.lastReadAt(space) == at)
    }

    @Test func typingIsAddedAndRemoved() throws {
        let store = try store()
        try store.apply([.setTyping(conversation: space, member: alice, isTyping: true)])
        #expect(try store.typingMembers(in: space) == [alice])

        try store.apply([.setTyping(conversation: space, member: alice, isTyping: false)])
        #expect(try store.typingMembers(in: space).isEmpty)
    }

    @Test func theLocalMemberIsReadableAndStartsUnset() throws {
        let store = try store()
        #expect(try store.me() == nil)

        try store.apply([.setLocalMember(alice)])
        #expect(try store.me() == alice)

        try store.apply([.setLocalMember(bob)])
        #expect(try store.me() == bob)
    }

    @Test func theConnectionStateAndLastErrorAreReadableAndTyped() throws {
        let store = try store()
        #expect(try store.connectionState() == .idle)

        try store.apply([
            .setConnectionState(.reconnecting(attempt: 4, issue: nil, detail: nil)),
            .setLastError(.rateLimited(retryAfter: .seconds(30)))
        ])

        #expect(try store.connectionState() == .reconnecting(attempt: 4, issue: nil, detail: nil))
        #expect(try store.lastError() == .rateLimited(retryAfter: .seconds(30)))

        try store.apply([.setLastError(nil)])
        #expect(try store.lastError() == nil)
    }

    /// Typing, presence, the connection state and the last error are all
    /// claims about *now*. Restoring them from disk would show someone typing a
    /// message they finished three days ago - or, as an actual launch did,
    /// report a connection that does not exist.
    @Test func clearingEphemeralStateDropsWhatWasOnlyTrueBefore() throws {
        let store = try store()
        try store.apply([
            .upsertConversation(conversation(space)),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .active),
            .setTyping(conversation: space, member: alice, isTyping: true),
            .setConnectionState(.connected),
            .setLastError(.sessionExpired),
            .upsertMessage(message("msg:1", in: space, at: at))
        ])

        try store.apply([.clearEphemeralState])

        #expect(try store.typingMembers(in: space).isEmpty)
        #expect(try store.members().first?.presence == nil)
        #expect(try store.connectionState() == .idle)
        #expect(try store.lastError() == nil)
    }

    /// The durable half must survive it, or "clear what is stale" quietly
    /// becomes "wipe the cache".
    @Test func clearingEphemeralStateKeepsEverythingDurable() throws {
        let store = try store()
        try store.apply([
            .upsertConversation(conversation(space)),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .upsertMessage(message("msg:1", in: space, at: at)),
            .setLocalMember(alice),
            .clearEphemeralState
        ])

        #expect(try store.members().count == 1)
        #expect(try store.conversations().count == 1)
        #expect(try store.messages(in: space).count == 1)
        // Who we are stays true across a relaunch, unlike the connection state
        // or the last error just above - it is not a claim about *now*.
        #expect(try store.me() == alice)
    }

    // MARK: - Missing references

    /// The store holds pages, not all of history, so a reaction or a deletion
    /// naming a message it has never seen is an ordinary runtime condition -
    /// not an error. Throwing here would let one old message kill the sync
    /// loop.
    @Test func writesAboutAMessageWeDoNotHoldAreQuietlyDropped() throws {
        let store = try store()
        try store.apply([
            .setReactions(messageID: Message.ID("msg:unheld"), reactions: []),
            .markMessageDeleted(id: Message.ID("msg:unheld"), in: space),
            // Routine rather than exceptional: `ChatSessionModel.send` skips
            // the optimistic write whenever the local member is not yet known,
            // so a failed send often has nothing to retract.
            .removeMessage(id: Message.ID("local/never-written")),
            .setReadState(conversation: Conversation.ID("space:unheld"), lastReadAt: at, unread: 1)
        ])
        #expect(try store.messages(in: space).isEmpty)
    }

    /// Membership for a conversation that does not exist is different in kind:
    /// not a partial cache, but an ordering the backend contract forbids -
    /// connect sends the conversation list before any membership. Surfacing it
    /// is worth more than absorbing it, and the engine turns a throw into a
    /// recorded error rather than a dead loop.
    @Test func membershipForAConversationTheStoreDoesNotHaveThrows() throws {
        let store = try store()
        #expect(throws: (any Error).self) {
            try store.apply([.setMembership(conversation: space, members: [alice])])
        }
    }

    /// One transaction per batch: an observer must never see half of an event.
    @Test func aBatchThatFailsPartWayLeavesNothingBehind() throws {
        let store = try store()
        try store.apply([.upsertConversation(conversation(space))])

        #expect(throws: (any Error).self) {
            try store.apply([
                .upsertMessage(message("msg:1", in: space, at: at)),
                .setMembership(conversation: Conversation.ID("space:nowhere"), members: [alice])
            ])
        }
        #expect(try store.messages(in: space).isEmpty)
    }
}
