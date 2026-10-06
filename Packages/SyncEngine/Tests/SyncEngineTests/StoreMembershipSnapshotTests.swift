import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// A space's world snapshot lists nobody (`findings.md` §43.1), while
/// `list_members` fills its membership (§56.1). Every conversation upsert used
/// to rewrite membership from the snapshot, so each world load or
/// `conversationUpdated` erased what `list_members` wrote (mention composer
/// spec §3.3). A conversation always contains the signed-in account, so an
/// empty list can only mean "not listed".
struct StoreMembershipSnapshotTests {
    private let space = Conversation.ID("space/s-1")

    private func members(_ store: ChatStore) throws -> [Member.ID] {
        try #require(store.conversations().first { $0.id == space }).members
    }

    @Test func aSnapshotListingNobodyKeepsTheStoredMembers() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])
        try store.apply([.setMembership(conversation: space, members: [Member.ID("u-1"), Member.ID("u-2")])])

        try store.apply([.upsertConversation(Conversation(id: space, kind: .space, title: "Renamed"))])

        #expect(try members(store) == [Member.ID("u-1"), Member.ID("u-2")])
    }

    /// The world load writes through `replaceConversations`, the same upsert.
    @Test func aWorldLoadListingNobodyKeepsTheStoredMembers() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])
        try store.apply([.setMembership(conversation: space, members: [Member.ID("u-1")])])

        try store.apply([.replaceConversations([Conversation(id: space, kind: .space)])])

        #expect(try members(store) == [Member.ID("u-1")])
    }

    /// The other direction: a snapshot that does list members is authoritative.
    @Test func aSnapshotListingMembersReplacesThem() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])
        try store.apply([.setMembership(conversation: space, members: [Member.ID("u-1")])])
        try store.apply([.upsertConversation(Conversation(
            id: space, kind: .space, members: [Member.ID("u-2"), Member.ID("u-3")]
        ))])

        #expect(try members(store) == [Member.ID("u-2"), Member.ID("u-3")])
    }

    /// `.membersChanged` (via `.setMembership`) still replaces outright.
    @Test func setMembershipStillReplaces() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(
            id: space,
            kind: .space,
            members: [Member.ID("u-1")]
        ))])
        try store.apply([.setMembership(conversation: space, members: [Member.ID("u-9")])])

        #expect(try members(store) == [Member.ID("u-9")])
    }
}
