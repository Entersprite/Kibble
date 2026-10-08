import ChatKit
import Foundation
import GRDB
import Testing
@testable import SyncEngine

/// Your availability in the store: a session value, like the connection
/// state, cleared at launch and learned again at connect (spec §4).
struct StoreAvailabilityTests {
    private let until = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func itLandsAndIsReadBack() throws {
        let store = try ChatStore.inMemory()
        #expect(try store.availability() == nil)
        try store.apply([.setAvailability(.doNotDisturb(until: until))])
        #expect(try store.availability() == .doNotDisturb(until: until))
        try store.apply([.setAvailability(.away)])
        #expect(try store.availability() == .away)
    }

    @Test func clearingEphemeralStateDropsIt() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.setAvailability(.away), .clearEphemeralState])
        #expect(try store.availability() == nil)
    }

    @Test func aStoreFromBeforeV12HasNone() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v11")
        let store = try ChatStore(queue)
        #expect(try store.availability() == nil)
    }
}
