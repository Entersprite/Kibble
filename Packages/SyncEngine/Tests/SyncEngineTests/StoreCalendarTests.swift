import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// `Member.calendar` through the store, with `status`'s life: written by an
/// UPDATE, carried through snapshots that carry none, dropped at launch.
struct StoreCalendarTests {
    private let alice = Member.ID("people/alice")
    private let meeting = CalendarSchedule(
        entries: [.init(
            start: Date(timeIntervalSince1970: 1_790_000_000),
            end: Date(timeIntervalSince1970: 1_790_003_600),
            kind: .inMeeting,
            until: Date(timeIntervalSince1970: 1_790_003_600)
        )],
        validUntil: Date(timeIntervalSince1970: 1_790_043_200)
    )

    private func storeWithAlice() throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMembers([Member(id: alice, kind: .human, displayName: "Alice")])])
        return store
    }

    @Test func aScheduleLandsAndClears() throws {
        let store = try storeWithAlice()
        try store.apply([.setCalendar(member: alice, schedule: meeting)])
        #expect(try store.members().first?.calendar == meeting)

        try store.apply([.setCalendar(member: alice, schedule: nil)])
        #expect(try store.members().first?.calendar == nil)
    }

    /// Every `get_members` answer carries no schedule; it must not wipe the
    /// one the poll recorded.
    @Test func aSnapshotWithNoScheduleKeepsTheRecordedOne() throws {
        let store = try storeWithAlice()
        try store.apply([
            .setCalendar(member: alice, schedule: meeting),
            .upsertMembers([Member(id: alice, kind: .human, displayName: "Alice Liddell")])
        ])
        #expect(try store.members().first?.calendar == meeting)
    }

    @Test func clearingEphemeralStateDropsIt() throws {
        let store = try storeWithAlice()
        try store.apply([.setCalendar(member: alice, schedule: meeting), .clearEphemeralState])
        #expect(try store.members().first?.calendar == nil)
    }

    /// An UPDATE: no nameless member row is invented.
    @Test func aScheduleForSomeoneUnknownIsDropped() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setCalendar(member: alice, schedule: meeting)])
        #expect(try store.members().isEmpty)
    }

    /// A row written before v11 has no calendar column, and reads back as none.
    @Test func aRowFromBeforeV11ReadsAsNoCalendar() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v10")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO member (id, kind, displayName) VALUES ('people/alice', 'human', 'Alice')"
            )
        }
        let store = try ChatStore(queue)
        #expect(try store.members().first?.calendar == nil)
        #expect(try store.members().first?.displayName == "Alice")
    }
}
