import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// `Member.status` through the store: the same life as presence - written by
/// an UPDATE, carried through snapshots that carry none, and dropped with the
/// rest of what is only true now.
struct StoreStatusTests {
    private let alice = Member.ID("people/alice")
    private let vacation = MemberStatus(
        emoji: "🌴",
        text: "On vacation",
        expiresAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    private func storeWithAlice() throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")])])
        return store
    }

    @Test func aStatusLandsAndClears() throws {
        let store = try storeWithAlice()
        try store.apply([.setStatus(member: alice, status: vacation)])
        #expect(try store.members().first?.status == vacation)

        try store.apply([.setStatus(member: alice, status: nil)])
        #expect(try store.members().first?.status == nil)
    }

    /// Every `get_members` answer carries no status; it must not wipe the one
    /// the poll recorded.
    @Test func aSnapshotWithNoStatusKeepsTheRecordedOne() throws {
        let store = try storeWithAlice()
        try store.apply([
            .setStatus(member: alice, status: vacation),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice Liddell")])
        ])
        #expect(try store.members().first?.status == vacation)
    }

    @Test func clearingEphemeralStateDropsIt() throws {
        let store = try storeWithAlice()
        try store.apply([.setStatus(member: alice, status: vacation), .clearEphemeralState])
        #expect(try store.members().first?.status == nil)
    }

    /// An UPDATE, like presence: no nameless member row is invented.
    @Test func aStatusForSomeoneUnknownIsDropped() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setStatus(member: alice, status: vacation)])
        #expect(try store.members().isEmpty)
    }

    /// A row written before v8 has no status column, and reads back as none.
    @Test func aRowFromBeforeV8ReadsAsNoStatus() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v7")
        try queue.write { db in
            try db
                .execute(
                    sql: "INSERT INTO member (id, kind, displayName) "
                        + "VALUES ('people/alice', 'human', 'Alice')"
                )
        }
        let store = try ChatStore(queue)
        #expect(try store.members().first?.status == nil)
        #expect(try store.members().first?.displayName == "Alice")
    }
}
