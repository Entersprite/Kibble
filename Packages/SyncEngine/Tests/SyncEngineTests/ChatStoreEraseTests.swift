import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `ChatStore.erase()` is what makes `AppEnvironment.signOut()` safe: one
/// database file serves every account that ever signs in on a Mac, and a
/// hand-written list of `DELETE FROM` statements is exactly the kind of list
/// a table added later gets left off. This is the test that would have
/// caught that - it writes to a table that is neither `message` nor
/// `conversation` on purpose, because those are the two a hand-written list
/// would remember.
struct ChatStoreEraseTests {
    private let space = Conversation.ID("space:1")
    private let alice = Member.ID("people/alice")
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    @Test func eraseClearsEveryTableIncludingOneThatIsNeitherMessageNorConversation() throws {
        let store = try ChatStore.inMemory()
        try store.apply([
            .upsertConversation(Conversation(id: space, kind: .space, title: "price-engine")),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setMembership(conversation: space, members: [alice]),
            .upsertMessage(Message(
                id: Message.ID("msg:1"),
                conversationID: space,
                threadID: MessageThread.ID("topic:1"),
                sender: alice,
                text: "hello",
                createdAt: at
            )),
            // Neither `message` nor `conversation` - the one the brief asks
            // for by name.
            .setTyping(conversation: space, member: alice, isTyping: true),
            .setLocalMember(alice),
            .setConnectionState(.connected),
            .setLastError(.sessionExpired)
        ])

        // Confirm the fixture actually landed, so an empty result below means
        // "erased" and not "never written".
        #expect(try store.conversations().count == 1)
        #expect(try store.members().count == 1)
        #expect(try store.messages(in: space).count == 1)
        #expect(try store.typingMembers(in: space).count == 1)
        #expect(try store.me() == alice)
        #expect(try store.connectionState() == .connected)
        #expect(try store.lastError() == .sessionExpired)

        try store.erase()

        #expect(try store.conversations().isEmpty)
        #expect(try store.members().isEmpty)
        #expect(try store.messages(in: space).isEmpty)
        #expect(try store.typingMembers(in: space).isEmpty)
        #expect(try store.me() == nil)
        #expect(try store.connectionState() == .idle)
        #expect(try store.lastError() == nil)
    }

    /// `erase()` drops GRDB's own migration bookkeeping along with every
    /// table it wipes, so a store that did not re-migrate in the same call
    /// would answer every read after this with "no such table" rather than
    /// an empty one - and the very next sign-in would crash instead of
    /// starting fresh. This proves the schema comes back, not just goes
    /// empty.
    @Test func theStoreIsUsableImmediatelyAfterErasing() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])

        try store.erase()

        try store.apply([.upsertConversation(Conversation(id: space, kind: .space, title: "new"))])
        #expect(try store.conversations().map(\.title) == ["new"])
    }
}
