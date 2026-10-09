import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `Conversation.hasUnreadThread` from both of its sources (threads spec
/// §4.2, CLAUDE.md's rule for a derived field), each moving both ways, and
/// the rule that a reply never marks its conversation unread (§4.3).
struct StoreUnreadThreadsTests {
    private let space = Conversation.ID("space/s")
    private let topic = MessageThread.ID("topic:1")
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")
    private let at = Date(timeIntervalSince1970: 1_790_000_000.128263)

    private func store(_ conversation: Conversation? = nil) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([
            .setLocalMember(me),
            .replaceConversations([conversation ?? Conversation(id: space, kind: .space)])
        ])
        return store
    }

    private func conversation(in store: ChatStore) throws -> Conversation? {
        try store.conversations().first { $0.id == space }
    }

    private func change(_ change: ThreadChange) -> StoreWrite {
        .applyThreadChange(thread: topic, conversation: space, change: change)
    }

    private func message(isReply: Bool, from sender: Member.ID? = nil) -> Message {
        Message(
            id: Message.ID(isReply ? "m:reply" : "m:top"), conversationID: space, threadID: topic,
            sender: sender ?? alice, text: "hi", createdAt: at, isReply: isReply
        )
    }

    private func flag(_ hasUnread: Bool) -> [StoreWrite] {
        SyncReducer.reduce(.unreadThreadsChanged(conversationID: space, hasUnread: hasUnread)).writes
    }

    /// Push 53, both ways, through the reducer.
    @Test func theServersFlagMovesBothWays() throws {
        let store = try store()
        try store.apply(flag(true))
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply(flag(false))
        #expect(try conversation(in: store)?.hasUnreadThread == false)
    }

    /// A world load writes both fields, and the next one can clear them: the
    /// snapshot is the server's word.
    @Test func aWorldLoadWritesBothFieldsAndTheNextOneClearsThem() throws {
        let both = Conversation(id: space, kind: .space, repliesEnabled: true, hasUnreadThread: true)
        let store = try store(both)
        #expect(try conversation(in: store)?.repliesEnabled == true)
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply([.replaceConversations([Conversation(id: space, kind: .space)])])
        #expect(try conversation(in: store)?.repliesEnabled == false)
        #expect(try conversation(in: store)?.hasUnreadThread == false)
    }

    @Test func aThreadMarkedUnreadRaisesItAndClearingTheMarkLowersIt() throws {
        let store = try store()
        try store.apply([change(.markedUnread(at: at))])
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply([change(.markedUnread(at: nil))])
        #expect(try conversation(in: store)?.hasUnreadThread == false)
    }

    /// The test that moves it back (spec §4.2): a counted unread thread raises
    /// it, and a read that covers the thread lowers it.
    @Test func aCountedUnreadThreadRaisesItAndAReadThatCoversItLowersIt() throws {
        let store = try store()
        try store.apply([.upsertMessage(message(isReply: true)), change(.counted(messages: 2, unread: 1))])
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply([change(.read(upTo: at))])
        #expect(try conversation(in: store)?.hasUnreadThread == false)
    }

    @Test func eitherSourceAloneRaisesIt() throws {
        let store = try store()
        try store.apply([change(.markedUnread(at: at))] + flag(false))
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply([change(.markedUnread(at: nil))] + flag(true))
        #expect(try conversation(in: store)?.hasUnreadThread == true)
    }

    /// Spec §4.2: "any of its stored threads is unread", by the thread's own
    /// rule, the fallback included, so the sidebar and the Threads badge
    /// agree. A read that covers the reply lowers it again (equality is read).
    @Test func theFallbackRuleRaisesIt() throws {
        let store = try store()
        try store.apply([
            .upsertMessage(message(isReply: true)), change(.followed(true)),
            change(.read(upTo: at.addingTimeInterval(-60)))
        ])
        #expect(try store.thread(topic, in: space)?.hasUnread == true)
        #expect(try conversation(in: store)?.hasUnreadThread == true)
        try store.apply([change(.read(upTo: at))])
        #expect(try conversation(in: store)?.hasUnreadThread == false)
    }

    /// `ThreadUnreadRule` decides, not the store's narrowing: a thread not
    /// followed, one whose only newer reply is your own, and one read to its
    /// reply's own time each leave the flag down.
    @Test func whereTheFallbackSaysReadItStaysDown() throws {
        let before = at.addingTimeInterval(-60)
        let cases: [[StoreWrite]] = [
            [.upsertMessage(message(isReply: true)), change(.followed(false)), change(.read(upTo: before))],
            [
                .upsertMessage(message(isReply: true, from: me)),
                change(.followed(true)),
                change(.read(upTo: before))
            ],
            [.upsertMessage(message(isReply: true)), change(.followed(true)), change(.read(upTo: at))]
        ]
        for writes in cases {
            let store = try store()
            try store.apply(writes)
            #expect(try store.thread(topic, in: space)?.hasUnread == false)
            #expect(try conversation(in: store)?.hasUnreadThread == false)
        }
    }

    /// Spec §4.3 through the reducer and the store: a reply from someone else
    /// leaves the conversation read, where a top-level message marks it.
    /// Seen red with the guard deleted (Step 15).
    @Test func aReplyLeavesItsConversationReadWhereATopLevelMessageDoesNot() throws {
        let store = try store()
        try store.apply(SyncReducer.reduce(.messageReceived(message(isReply: true))).writes)
        #expect(try conversation(in: store)?.hasUnread == false)
        try store.apply(SyncReducer.reduce(.messageReceived(message(isReply: false))).writes)
        #expect(try conversation(in: store)?.hasUnread == true)
    }
}
