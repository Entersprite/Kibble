import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public extension SQLiteAccountRegistry {
    internal static func addLinkHistoryMigration(to migrations: inout DatabaseMigrator) {
        migrations.registerMigration("accountRegistry6") { db in
            try db.execute(sql: """
            ALTER TABLE registryLifecycle ADD COLUMN linkFloor REAL NOT NULL DEFAULT 0;
            ALTER TABLE accountLink ADD COLUMN phase TEXT;
            ALTER TABLE accountLink ADD COLUMN bornAt REAL;
            CREATE INDEX accountLinkHistory ON accountLink(phase, bornAt);
            """)
            for row in try Row.fetchAll(db, sql: "SELECT id, record FROM accountLink") {
                let link = try ServiceCodec.decode(AccountLinkRecord.self, from: row["record"] as Data)
                try db.execute(sql: "UPDATE accountLink SET phase = ?, bornAt = ? WHERE id = ?", arguments: [
                    link.phase, ClientOperationID.createdAt(link.operationID.rawValue)?.timeIntervalSince1970,
                    row["id"] as String
                ])
            }
        }
    }

    func pruneLinkHistory() throws -> [AccountLinkID] {
        try database.write { db in
            let floor = try linkFloor(db)
            let condition = "phase IN ('completed', 'canceled', 'alreadyConnected') AND bornAt < ?"
            let removed = try String.fetchAll(
                db,
                sql: "SELECT id FROM accountLink WHERE " + condition,
                arguments: [floor]
            )
            try db.execute(sql: "DELETE FROM accountLink WHERE " + condition, arguments: [floor])
            return removed.map { AccountLinkID($0) }
        }
    }

    func admitNewLinkOperation(_ id: ServiceOperationID, principal: ServicePrincipalID) throws {
        try database.write { db in
            let floor = try linkFloor(db)
            let raw = id.rawValue
            guard !raw.isEmpty, raw.utf8.count <= 128 else { throw ServiceFailure.invalidRequest }
            if raw.hasPrefix("op1:") {
                guard let birth = ClientOperationID.createdAt(raw)?.timeIntervalSince1970 else {
                    throw ServiceFailure.invalidRequest
                }
                guard birth >= floor else { throw ServiceFailure.operationExpired }
                guard birth <= floor + linkRetention.maximumAge + 300
                else { throw ServiceFailure.invalidRequest }
            } else {
                let legacy = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM accountLink WHERE principal = ? AND bornAt IS NULL
                """, arguments: [principal.rawValue]) ?? 0
                guard legacy < linkRetention.legacyOperationCount else { throw ServiceFailure.overloaded }
            }
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM accountLink WHERE principal = ?",
                arguments: [principal.rawValue]
            ) ?? 0
            guard count < linkRetention.operationCount,
                  count < linkRetention.operationBytes / (16 * 1024) else { throw ServiceFailure.overloaded }
        }
    }

    private func linkFloor(_ db: Database) throws -> TimeInterval {
        let previous = try Double
            .fetchOne(db, sql: "SELECT linkFloor FROM registryLifecycle WHERE id = 1") ?? 0
        let floor = max(previous, retentionClock().timeIntervalSince1970 - linkRetention.maximumAge)
        try db.execute(sql: "UPDATE registryLifecycle SET linkFloor = ? WHERE id = 1", arguments: [floor])
        return floor
    }
}
