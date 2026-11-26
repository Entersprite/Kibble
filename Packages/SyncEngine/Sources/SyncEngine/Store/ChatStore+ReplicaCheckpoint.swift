import ChatKit
import ChatRules
import Foundation
import GRDB

public extension ChatStore {
    func replicaCheckpoint() throws -> ReplicaCheckpoint? {
        try database.read { db in
            guard try db.tableExists("replicaCheckpoint") else { return nil }
            return try Self.fetchReplicaCheckpoint(db)
        }
    }

    /// Returns false for an already committed delivery; no write or effect is repeated.
    func applyCheckpointed(_ writes: [StoreWrite], checkpoint: ReplicaCheckpoint) throws -> Bool {
        try database.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS replicaCheckpoint (
                id INTEGER PRIMARY KEY, value BLOB NOT NULL
            )
            """)
            if let previous = try Self.fetchReplicaCheckpoint(db) {
                guard previous.account == checkpoint.account else {
                    throw ChatError.decoding("The replica belongs to another account.")
                }
                if previous.stream == checkpoint.stream,
                   previous.sequence >= checkpoint.sequence {
                    return false
                }
            }
            try Self.apply(writes, in: db)
            try db.execute(
                sql: """
                INSERT INTO replicaCheckpoint (id, value) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET value = excluded.value
                """,
                arguments: [JSONEncoder().encode(checkpoint)]
            )
            return true
        }
    }

    private static func fetchReplicaCheckpoint(_ db: Database) throws -> ReplicaCheckpoint? {
        try Data.fetchOne(db, sql: "SELECT value FROM replicaCheckpoint WHERE id = 1")
            .map { try JSONDecoder().decode(ReplicaCheckpoint.self, from: $0) }
    }
}
