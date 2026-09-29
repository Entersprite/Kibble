import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Presence against the member snapshots that carry none. Split from
/// `StoreWriteTests` for `file_length`.
struct StorePresenceTests {
    private let alice = Member.ID("people/alice")

    private func store() throws -> ChatStore {
        try ChatStore.inMemory()
    }

    /// A member snapshot that says nothing about presence - every
    /// `get_members` answer, which is where names come from - must not wipe
    /// the presence a poll already recorded. Otherwise a new sender's name
    /// lookup in a space would blank the dot of someone you DM.
    @Test func aSnapshotWithNoPresenceKeepsTheRecordedOne() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .active),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice Liddell")])
        ])
        let member = try #require(try store.members().first)
        #expect(member.displayName == "Alice Liddell")
        #expect(member.presence == .active)
    }

    /// The carry-forward is for `nil` only: a snapshot that does carry a
    /// presence - the fixture's members do - is authoritative.
    @Test func aSnapshotWithAPresenceReplacesTheRecordedOne() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .active),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice", presence: .inactive)])
        ])
        #expect(try store.members().first?.presence == .inactive)
    }
}
