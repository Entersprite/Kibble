import GRDB
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct SnapshotBufferTests {
    /// Deliver on the writer's queue so each completed write also proves that
    /// its snapshot reached the buffer. No timing or task scheduling guesses.
    private struct WriterScheduler: ValueObservationScheduler {
        func immediateInitialValue() -> Bool {
            false
        }

        func schedule(_ action: @escaping @Sendable () -> Void) {
            action()
        }
    }

    @Test func aPausedConsumerResumesWithTheCompleteLatestSnapshot() async throws {
        let database = try DatabaseQueue()
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
        }
        var iterator = ValueObservation.tracking { db in
            try Int.fetchAll(db, sql: "SELECT id FROM items ORDER BY id")
        }.snapshotValues(in: database, scheduling: WriterScheduler()).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])

        // The iterator is deliberately idle while the database keeps changing.
        for id in 1 ... 100 {
            try await database.write { db in
                try db.execute(sql: "INSERT INTO items VALUES (?)", arguments: [id])
            }
        }
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
        }.snapshotValues(in: database, scheduling: WriterScheduler()).makeAsyncIterator()
        await #expect(throws: DatabaseError.self) {
            _ = try await iterator.next()
        }
    }
}
