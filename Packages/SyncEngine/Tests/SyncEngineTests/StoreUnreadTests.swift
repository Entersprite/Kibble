import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The unread flag's lifecycle - set on arrival, cleared on read.
///
/// Its own file rather than more of `StoreWriteTests`, which crossed
/// `swiftlint`'s 400-line `file_length` and 300-line `type_body_length` when
/// these were added. It is a coherent split: every test here is about one
/// column moving in both directions, which is precisely the bug that prompted
/// them.
///
/// The flag shipped moving **neither** way. `WorldMapping` wrote it once from
/// `paginated_world` and nothing in the event stream maintained it, so the dot
/// never appeared for a message that arrived after launch and never cleared
/// when the conversation was read (`findings.md` §37.8).
struct StoreUnreadTests {
    private let space = Conversation.ID("space:1")
    private let alice = Member.ID("people/alice")
    private let bob = Member.ID("people/bob")
    private let at = Date(timeIntervalSince1970: 1_788_166_800)

    private func store() throws -> ChatStore {
        try ChatStore.inMemory()
    }

    private func conversation(_ id: Conversation.ID) -> Conversation {
        Conversation(id: id, kind: .space)
    }

    /// Sent by `alice`, so a test can make her the local member to exercise
    /// the self-exclusion and `bob` to exercise the ordinary path.
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

    /// The flag has to move **both** ways. It shipped moving neither: it was
    /// written once by the world mapping and nothing in the event stream
    /// maintained it, so the dot never appeared for a new message and never
    /// cleared when the conversation was read.
    private func hasUnread(_ id: Conversation.ID, in store: ChatStore) throws -> Bool? {
        try store.conversations().first { $0.id == id }?.hasUnread
    }

    @Test func aMessageFromSomebodyElseMarksTheConversationUnread() throws {
        let store = try store()
        try store.apply([.setLocalMember(bob), .replaceConversations([conversation(space)])])
        #expect(try hasUnread(space, in: store) == false)

        try store.apply(SyncReducer.reduce(.messageReceived(message("m:1", in: space, at: at))).writes)
        #expect(try hasUnread(space, in: store) == true)
    }

    /// The local user's own message must not mark their own conversation
    /// unread. Without this the dot appears on the row being typed in and
    /// stays for the two seconds until the debounced auto-mark clears it.
    @Test func myOwnMessageDoesNotMarkMyConversationUnread() throws {
        let store = try store()
        try store.apply([.setLocalMember(alice), .replaceConversations([conversation(space)])])

        // `message(_:in:at:)` sends as `alice`, who is the local member here.
        try store.apply(SyncReducer.reduce(.messageReceived(message("m:1", in: space, at: at))).writes)
        #expect(try hasUnread(space, in: store) == false)
    }

    /// Nothing else clears it, so if this write does not, the dot is permanent.
    @Test func aReadStateChangeClearsUnread() throws {
        let store = try store()
        try store.apply([.setLocalMember(bob), .replaceConversations([conversation(space)])])
        try store.apply(SyncReducer.reduce(.messageReceived(message("m:1", in: space, at: at))).writes)
        #expect(try hasUnread(space, in: store) == true)

        try store.apply([.setReadState(conversation: space, lastReadAt: at, unread: 0)])
        #expect(try hasUnread(space, in: store) == false)
    }

    /// An **edit** to a message already read must not raise the dot again.
    /// `messageReceived` and `messageUpdated` shared one reducer case until
    /// unread existed; this is what that split is for.
    @Test func editingAMessageDoesNotMarkTheConversationUnread() throws {
        let store = try store()
        try store.apply([.setLocalMember(bob), .replaceConversations([conversation(space)])])
        try store.apply(SyncReducer.reduce(.messageReceived(message("m:1", in: space, at: at))).writes)
        try store.apply([.setReadState(conversation: space, lastReadAt: at, unread: 0)])
        #expect(try hasUnread(space, in: store) == false)

        try store.apply(SyncReducer.reduce(.messageUpdated(message("m:1", in: space, at: at))).writes)
        #expect(try hasUnread(space, in: store) == false)
    }
}
