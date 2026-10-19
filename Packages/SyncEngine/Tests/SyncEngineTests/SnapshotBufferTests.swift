import Foundation
import GRDB
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct SnapshotBufferTests {
    /// Database writes finish before GRDB's reduction queue delivers the
    /// corresponding value. Count completed yields on that queue.
    private final class DeliveryScheduler: ValueObservationScheduler, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var delivered: Int {
            lock.withLock { count }
        }

        func immediateInitialValue() -> Bool {
            false
        }

        func schedule(_ action: @escaping @Sendable () -> Void) {
            action()
            lock.withLock { count += 1 }
        }
    }

    @Test func aPausedConsumerResumesWithTheCompleteLatestSnapshot() async throws {
        let database = try DatabaseQueue()
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        let scheduler = DeliveryScheduler()
        var iterator = ValueObservation.tracking { db in
            try Int.fetchAll(db, sql: "SELECT id FROM items ORDER BY id")
        }.snapshotValues(in: database, scheduling: scheduler).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])

        // The iterator is deliberately idle while the database keeps changing.
        for id in 1 ... 100 {
            try await database.write { db in
                try db.execute(sql: "INSERT INTO items VALUES (?)", arguments: [id])
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while scheduler.delivered < 101, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(scheduler.delivered == 101)
        let resumed = try await iterator.next()
        #expect(resumed == Array(1 ... 100))

        try await database.write { db in
            try db.execute(sql: "DELETE FROM items WHERE id < 100")
        }
        let following = try await iterator.next()
        #expect(following == [100])
    }

    @Test func snapshotObservationStillReportsQueryFailures() async throws {
        let database = try DatabaseQueue()
        var iterator = ValueObservation.tracking { db in
            try Int.fetchAll(db, sql: "SELECT id FROM missing_table")
        }.snapshotValues(in: database, scheduling: DeliveryScheduler()).makeAsyncIterator()
        await #expect(throws: DatabaseError.self) {
            _ = try await iterator.next()
        }
    }
}
