import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `Conversation.readPosition` in the store: one column (`lastReadAt`), two
/// sources (the mentions-list spec §1). Each direction has its own test,
/// because a field with a setter and no clearer passes every test that only
/// ever drives it one way (`CLAUDE.md`).
struct StoreReadPositionTests {
    private let space = Conversation.ID("space/s")
    private let fromWorld = Date(timeIntervalSince1970: 1_790_000_000.128263)
    private let fromMark = Date(timeIntervalSince1970: 1_790_000_060.000417)

    private func conversation(readPosition: Date?) -> Conversation {
        Conversation(id: space, kind: .space, readPosition: readPosition)
    }

    private func apply(_ event: ChatEvent, to store: ChatStore) throws {
        try store.apply(SyncReducer.reduce(event).writes)
    }

    private func stored(_ store: ChatStore) throws -> Int64? {
        try microseconds(store.conversations().first?.readPosition)
    }

    @Test func aWorldLoadSetsItToTheMicrosecond() throws {
        let store = try ChatStore.inMemory()
        try apply(.conversationsChanged([conversation(readPosition: fromWorld)]), to: store)
        #expect(try stored(store) == 1_790_000_000_128_263)
    }

    @Test func readStateChangedMovesIt() throws {
        let store = try ChatStore.inMemory()
        try apply(.conversationsChanged([conversation(readPosition: fromWorld)]), to: store)
        try apply(.readStateChanged(conversationID: space, lastReadAt: fromMark, unread: 0), to: store)
        #expect(try stored(store) == 1_790_000_060_000_417)
    }

    @Test func anArrivingMessageLeavesItAlone() throws {
        let store = try ChatStore.inMemory()
        try apply(.conversationsChanged([conversation(readPosition: fromWorld)]), to: store)
        try apply(.messageReceived(Message(
            id: Message.ID("m:1"), conversationID: space, threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: "hi", createdAt: fromMark
        )), to: store)
        #expect(try stored(store) == 1_790_000_000_128_263)
    }

    /// A world load's position is Google's current read state and is
    /// written as given, even over a later value the store holds. The
    /// carry-forward is for a snapshot that says nothing, never for one that
    /// says something older.
    @Test func aLaterWorldLoadWinsOverTheStoredPosition() throws {
        let store = try ChatStore.inMemory()
        try apply(.conversationsChanged([conversation(readPosition: nil)]), to: store)
        try apply(.readStateChanged(conversationID: space, lastReadAt: fromMark, unread: 0), to: store)
        try apply(.conversationsChanged([conversation(readPosition: fromWorld)]), to: store)
        #expect(try stored(store) == 1_790_000_000_128_263)
    }

    /// A snapshot with no position (a world item with no `last_read_time`,
    /// or a fixture's `conversationUpdated`) keeps the one the store holds.
    @Test func aSnapshotWithNoPositionKeepsTheStoredOne() throws {
        let store = try ChatStore.inMemory()
        try apply(.conversationsChanged([conversation(readPosition: nil)]), to: store)
        try apply(.readStateChanged(conversationID: space, lastReadAt: fromMark, unread: 0), to: store)
        try apply(.conversationsChanged([conversation(readPosition: nil)]), to: store)
        try apply(.conversationUpdated(conversation(readPosition: nil)), to: store)
        #expect(try stored(store) == 1_790_000_060_000_417)
    }
}
