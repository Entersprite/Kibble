import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The store's whole reason for existing: a view iterates one of these and
/// never learns that a backend exists. If observation does not fire, the app
/// looks frozen while being perfectly correct underneath, which is a horrible
/// bug to chase - so it is pinned here.
@Suite(.timeLimit(.minutes(1)))
struct ObservationTests {
    private let space = Conversation.ID("space:1")
    private let alice = Member.ID("people/alice")
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    private func message(_ id: String, _ text: String, offset: TimeInterval = 0) -> Message {
        Message(
            id: Message.ID(id),
            conversationID: space,
            threadID: MessageThread.ID("topic:1"),
            sender: alice,
            text: text,
            createdAt: at.addingTimeInterval(offset)
        )
    }

    /// GRDB emits the current value immediately, then again on each change, so
    /// a view has something to draw before anything happens.
    @Test func conversationsEmitOnceImmediatelyAndAgainOnChange() async throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space, title: "first"))])

        var iterator = store.observeConversations().makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial?.map(\.title) == ["first"])

        try store.apply([
            .upsertConversation(Conversation(id: space, kind: .space, title: "renamed"))
        ])

        let afterChange = try await iterator.next()
        #expect(afterChange?.map(\.title) == ["renamed"])
    }

    @Test func messagesEmitWhenOneArrives() async throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("msg:1", "hello"))])

        var iterator = store.observeMessages(in: space).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.text) == ["hello"])

        try store.apply([.upsertMessage(message("msg:2", "and again", offset: 60))])

        #expect(try await iterator.next()?.map(\.text) == ["hello", "and again"])
    }

    /// Typing is in the database precisely so that this works. If it were
    /// delivered beside the store, a view would need a second input and the
    /// rule that the UI observes the store would be a half-rule.
    @Test func typingEmitsLikeAnythingElse() async throws {
        let store = try ChatStore.inMemory()
        var iterator = store.observeTypingMembers(in: space).makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        try store.apply([.setTyping(conversation: space, member: alice, isTyping: true)])

        #expect(try await iterator.next() == [alice])
    }

    @Test func theConnectionStateEmitsForTheBanner() async throws {
        let store = try ChatStore.inMemory()
        var iterator = store.observeConnectionState().makeAsyncIterator()
        #expect(try await iterator.next() == .idle)

        try store.apply([.setConnectionState(.connected)])

        #expect(try await iterator.next() == .connected)
    }

    /// `ChatSessionModel.me` rests on this: it watches `observeMe()` exactly
    /// like the connection state above, rather than taking a value once at
    /// init.
    ///
    /// `Member.ID?` is itself the observed value, so each `next()` hands back
    /// `Member.ID??` - the outer optional is "the stream ended", the inner one
    /// is "nobody has told us yet". `.flatMap { $0 }` flattens that outer
    /// layer away so the assertion is about the value, not the stream -
    /// `?? nil` would say the same thing but swiftlint reads it as always
    /// redundant, which here it is not.
    @Test func theLocalMemberEmitsOnceImmediatelyAndAgainWhenIdentified() async throws {
        let store = try ChatStore.inMemory()
        var iterator = store.observeMe().makeAsyncIterator()
        let initial = try await iterator.next().flatMap(\.self)
        #expect(initial == nil)

        try store.apply([.setLocalMember(alice)])

        let after = try await iterator.next().flatMap(\.self)
        #expect(after == alice)
    }

    /// A write to an unrelated table must not wake a message observer, or every
    /// keystroke somewhere else redraws a thread.
    @Test func anObserverIsNotWokenByAnUnrelatedTable() async throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("msg:1", "hello"))])

        var iterator = store.observeMessages(in: space).makeAsyncIterator()
        #expect(try await iterator.next()?.count == 1)

        try store.apply([.setConnectionState(.connected)])
        try store.apply([.upsertMessage(message("msg:2", "second", offset: 60))])

        // If the connection-state write had woken this observer, the next value
        // would still have one message in it.
        #expect(try await iterator.next()?.count == 2)
    }
}
