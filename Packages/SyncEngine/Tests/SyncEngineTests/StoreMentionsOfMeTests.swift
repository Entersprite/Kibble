import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// `ChatStore.mentionsOfMe`: the Mentions list as a query over the store
/// (the mentions-list spec §3). "Mentions me" is `Message.mentionsMe`, the one
/// definition notifications also use.
@Suite(.timeLimit(.minutes(1)))
struct StoreMentionsOfMeTests {
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let space = Conversation.ID("space/s")
    /// Off a millisecond on purpose: the boundary must hold through REAL columns.
    private let position = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func message(
        _ id: String, from sender: Member.ID? = nil, at createdAt: Date,
        mentions targets: [Mention.Target] = [], isDeleted: Bool = false
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: MessageThread.ID("t"),
            sender: sender ?? alice, text: "@Me hello", createdAt: createdAt, isDeleted: isDeleted,
            mentions: targets.map { Mention(target: $0, start: 0, length: 3) }
        )
    }

    private func store(
        readPosition: Date? = nil, isMuted: Bool = false, identified: Bool = true
    ) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        var writes: [StoreWrite] = [.replaceConversations([
            Conversation(
                id: space,
                kind: .space,
                title: "Design",
                isMuted: isMuted,
                readPosition: readPosition
            )
        ])]
        if identified {
            writes.append(.setLocalMember(me))
        }
        try store.apply(writes)
        return store
    }

    @Test func aMentionOfMeAndAnAllAreListedNewestFirstWithTheirConversation() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message("m:me", at: position, mentions: [.user(me)])),
            .upsertMessage(message("m:all", at: position.addingTimeInterval(60), mentions: [.all]))
        ])
        let found = try store.mentionsOfMe()
        #expect(found.map(\.message.id.rawValue) == ["m:all", "m:me"])
        #expect(found.first?.conversation.title == "Design")
    }

    /// `isDeleted` has its own row: a message stored deleted *with* mentions
    /// is excluded by the query's own filter, not by the tombstone write.
    @Test func myOwnMessageADeletedOneSomeoneElsesMentionAndAPlainOneAreNot() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message("m:mine", from: me, at: position, mentions: [.user(me), .all])),
            .upsertMessage(message("m:deleted", at: position, mentions: [.user(me)], isDeleted: true)),
            .upsertMessage(message("m:alice", at: position, mentions: [.user(alice)])),
            .upsertMessage(message("m:plain", at: position))
        ])
        #expect(try store.mentionsOfMe().isEmpty)
    }

    /// Spec §5: a tombstone drops its mentions (`90ec87a`) and leaves the list.
    @Test func aTombstoneLeavesTheList() throws {
        let store = try store()
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        try store.apply([.markMessageDeleted(id: Message.ID("m:1"), in: space)])
        #expect(try store.mentionsOfMe().isEmpty)
    }

    @Test func theLimitKeepsTheNewest() throws {
        let store = try store()
        try store.apply((0 ..< 3).map { index in
            StoreWrite.upsertMessage(
                message("m:\(index)", at: position.addingTimeInterval(Double(index)), mentions: [.user(me)])
            )
        })
        #expect(try store.mentionsOfMe(limit: 2).map(\.message.id.rawValue) == ["m:2", "m:1"])
    }

    /// Review Focus 1. Equality is read (`findings.md` §42.2), to the
    /// microsecond, through the store's REAL columns. A millisecond store
    /// would tie all three of these.
    @Test func aMentionAtTheReadPositionIsReadAndOneMicrosecondLaterIsUnread() throws {
        let store = try store(readPosition: position)
        try store.apply([
            .upsertMessage(message(
                "m:before", at: position.addingTimeInterval(-0.000_001), mentions: [.user(me)]
            )),
            .upsertMessage(message("m:at", at: position, mentions: [.user(me)])),
            .upsertMessage(message(
                "m:after", at: position.addingTimeInterval(0.000_001), mentions: [.user(me)]
            ))
        ])
        let states = try store.mentionsOfMe().map { "\($0.message.id.rawValue)=\($0.isUnread)" }
        #expect(states == ["m:after=true", "m:at=false", "m:before=false"])
        #expect(try store.unreadMentionCount() == 1)
    }

    @Test func withNoReadPositionAMentionIsUnread() throws {
        let store = try store(readPosition: nil)
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        #expect(try store.mentionsOfMe().first?.isUnread == true)
        #expect(try store.unreadMentionCount() == 1)
    }

    /// Review Focus 3. The list is observed at launch, and on a first-ever
    /// launch the account is not identified yet. `me` is read inside the
    /// query, so identifying it re-runs the observation. A `me` captured when
    /// the observation began would leave the list empty until a relaunch.
    @Test func identifyingTheAccountFillsAListAlreadyBeingObserved() async throws {
        let store = try store(identified: false)
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        var iterator = store.observeMentionsOfMe().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try store.apply([.setLocalMember(me)])
        #expect(try await iterator.next()?.map(\.message.id.rawValue) == ["m:1"])
    }

    /// `me` is read as one column, so the list and the badge track
    /// `syncState.localMemberID` and no other column of it. GRDB fetches on
    /// the writer at each commit that touches a region and delivers in commit
    /// order, so had either write below re-run a query, the next value would
    /// be the unchanged one rather than the mention.
    @Test func aWriteToAnotherSyncStateColumnReRunsNeitherObservation() async throws {
        let store = try store()
        var list = store.observeMentionsOfMe().makeAsyncIterator()
        var count = store.observeUnreadMentionCount().makeAsyncIterator()
        #expect(try await list.next()?.isEmpty == true)
        #expect(try await count.next() == 0)
        try store.apply([.setConnectionState(.connected)])
        try store.apply([.setMentionBackfill(MentionBackfillStatus(running: true))])
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        #expect(try await list.next()?.map(\.message.id.rawValue) == ["m:1"])
        #expect(try await count.next() == 1)
    }

    /// Review Focus 4. `messageUpdated` re-upserts `mentions` (spec §5), so an
    /// edit that removes the mention takes it off the list *and* the badge.
    @Test func anEditThatRemovesTheMentionTakesItOffTheListAndTheBadge() throws {
        let store = try store()
        let original = message("m:1", at: position, mentions: [.user(me)])
        try store.apply([.upsertMessage(original)])
        #expect(try store.unreadMentionCount() == 1)
        var edited = original
        edited.text = "hello"
        edited.mentions = []
        try store.apply(SyncReducer.reduce(.messageUpdated(edited)).writes)
        #expect(try store.mentionsOfMe().isEmpty)
        #expect(try store.unreadMentionCount() == 0)
    }

    /// Ruling 4: an orphaned message (its conversation dropped by a world
    /// load) has no title to draw and nothing to open.
    @Test func aMentionInAConversationTheStoreNoLongerListsIsNotListed() throws {
        let store = try store()
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        try store.apply([.replaceConversations([])])
        #expect(try store.mentionsOfMe().isEmpty)
        #expect(try store.unreadMentionCount() == 0)
    }

    /// The badge's observation re-runs on a conversation write: reading the
    /// conversation clears its mentions (spec §4).
    @Test func theUnreadCountFollowsTheReadPosition() async throws {
        let store = try store(readPosition: position)
        let later = position.addingTimeInterval(60)
        try store.apply([.upsertMessage(message("m:1", at: later, mentions: [.user(me)]))])
        var iterator = store.observeUnreadMentionCount().makeAsyncIterator()
        #expect(try await iterator.next() == 1)
        try store.apply(SyncReducer.reduce(
            .readStateChanged(conversationID: space, lastReadAt: later, unread: 0)
        ).writes)
        #expect(try await iterator.next() == 0)
    }

    /// Spec §3: rules do not hide mentions. Google's own mute is on the row.
    @Test func aMutedConversationsMentionIsListed() throws {
        let store = try store(isMuted: true)
        try store.apply([.upsertMessage(message("m:1", at: position, mentions: [.user(me)]))])
        #expect(try store.mentionsOfMe().count == 1)
    }
}
