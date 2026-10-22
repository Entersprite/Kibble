import ChatKit
import Foundation
import Testing
@testable import ChatPersistence
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

    // MARK: - Do not disturb's end

    /// A value that is not a whole millisecond, so the round trip shows the
    /// column keeps what the poll said rather than something near it.
    private let end = Date(timeIntervalSince1970: 1_790_000_000.123456)

    @Test func aDoNotDisturbEndIsStoredWithItsPresence() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .doNotDisturb, doNotDisturbUntil: end)
        ])
        let member = try #require(try store.members().first)
        #expect(member.presence == .doNotDisturb)
        let stored = try #require(member.doNotDisturbUntil)
        #expect(abs(stored.timeIntervalSince(end)) < 0.000_001)
    }

    /// Leaving Do not disturb takes the old end with it: the end is written
    /// with every presence, including one that has none.
    @Test func aPresenceWithoutAnEndClearsTheOldOne() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .doNotDisturb, doNotDisturbUntil: end),
            .setPresence(member: alice, presence: .active)
        ])
        let member = try #require(try store.members().first)
        #expect(member.presence == .active)
        #expect(member.doNotDisturbUntil == nil)
    }

    /// A name lookup carries neither, so both are kept, together.
    @Test func aSnapshotWithNoPresenceKeepsTheEndToo() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .doNotDisturb, doNotDisturbUntil: end),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice Liddell")])
        ])
        let member = try #require(try store.members().first)
        #expect(member.presence == .doNotDisturb)
        #expect(member.doNotDisturbUntil != nil)
    }

    /// A claim about now, so a fresh process starts without it.
    @Test func startupClearsTheEndWithThePresence() throws {
        let store = try store()
        try store.apply([
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")]),
            .setPresence(member: alice, presence: .doNotDisturb, doNotDisturbUntil: end),
            .clearEphemeralState
        ])
        let member = try #require(try store.members().first)
        #expect(member.presence == nil)
        #expect(member.doNotDisturbUntil == nil)
    }
}
