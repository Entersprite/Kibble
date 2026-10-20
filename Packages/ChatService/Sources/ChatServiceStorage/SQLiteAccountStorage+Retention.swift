import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage {
    static func initializeRetention(_ db: Database) throws {
        if try !db.columns(in: "serviceMetadata").contains(where: { $0.name == "operationFloor" }) {
            try db
                .execute(sql: "ALTER TABLE serviceMetadata ADD COLUMN operationFloor REAL NOT NULL DEFAULT 0")
        }
        if try !db.columns(in: "serviceJournal").contains(where: { $0.name == "recordedAt" }) {
            try db.execute(sql: "ALTER TABLE serviceJournal ADD COLUMN recordedAt REAL NOT NULL DEFAULT 0")
        }
        if try !db.columns(in: "serviceOperation").contains(where: { $0.name == "expiresAt" }) {
            try db.execute(sql: "ALTER TABLE serviceOperation ADD COLUMN expiresAt REAL")
        }
        try db
            .execute(sql: "CREATE INDEX IF NOT EXISTS serviceOperationExpiry ON serviceOperation(expiresAt)")
    }

    func retentionInstant(_ db: Database) throws -> TimeInterval {
        let floor = try Double
            .fetchOne(db, sql: "SELECT operationFloor FROM serviceMetadata WHERE id = 1") ?? 0
        return max(retentionClock().timeIntervalSince1970, floor + limits.maximumAge)
    }

    func pruneRetention(_ db: Database) throws {
        let instant = try retentionInstant(db)
        let floor = instant - limits.maximumAge
        try db.execute(sql: "UPDATE serviceMetadata SET operationFloor = ? WHERE id = 1", arguments: [floor])
        try db.execute(sql: "DELETE FROM serviceOperation WHERE expiresAt < ?", arguments: [instant])
        try db.execute(sql: "DELETE FROM serviceJournal WHERE recordedAt < ?", arguments: [floor])
        try db.execute(sql: """
        DELETE FROM serviceJournal WHERE sequence NOT IN (
            SELECT sequence FROM (
                SELECT sequence, SUM(length(event)) OVER (ORDER BY sequence DESC) AS retainedBytes
                FROM serviceJournal
            ) WHERE retainedBytes <= ?
        )
        """, arguments: [limits.journalBytes])
    }

    func operationExpiry(_ id: ServiceOperationID, db: Database) throws -> TimeInterval? {
        let raw = id.rawValue.hasPrefix("send:") ? String(id.rawValue.dropFirst(5)) : id.rawValue
        guard raw.hasPrefix("op1:") else { return nil }
        guard let created = ClientOperationID.createdAt(raw) else { throw ServiceFailure.invalidRequest }
        let instant = try retentionInstant(db)
        let birth = created.timeIntervalSince1970
        guard birth >= instant - limits.maximumAge else { throw ServiceFailure.operationExpired }
        guard birth <= instant + 300 else { throw ServiceFailure.invalidRequest }
        return birth + limits.maximumAge
    }

    func checkOperationCapacity(_ db: Database, bytes: Int, legacy: Bool) throws {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM serviceOperation") ?? 0
        let stored = try Int.fetchOne(
            db,
            sql: "SELECT SUM(length(request) + length(value)) FROM serviceOperation"
        ) ?? 0
        guard count < limits.operationCount, bytes <= limits.operationBytes - stored else {
            throw ServiceFailure.overloaded
        }
        if legacy {
            let legacyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM serviceOperation WHERE expiresAt IS NULL"
            ) ?? 0
            guard legacyCount < limits.legacyOperationCount else { throw ServiceFailure.overloaded }
        }
    }
}
