import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public extension SQLiteAccountRegistry {
    func policy(for account: AccountRecord) throws -> AccountPolicy {
        try database.read { db in try Self.policy(for: account, in: db) }
    }

    func setPolicy(
        _ settings: NotificationSettings,
        for account: AccountRecord,
        expectedRevision: String
    ) throws -> AccountPolicy {
        guard settings.schemaVersion == NotificationSettings.currentSchemaVersion
        else { throw ServiceFailure.unsupportedOperation }
        let bytes = try ServiceCodec.encode(settings)
        guard bytes.count <= 1024 * 1024
        else { throw ServiceFailure.frameTooLarge }
        guard Set(settings.records.map(\.scope)).count == settings.records.count
        else { throw ServiceFailure.invalidRequest }
        return try database.write { db in
            let previous = try Self.policy(for: account, in: db)
            guard previous.revision == expectedRevision,
                  let revision = Int64(previous.revision) else { throw ServiceFailure.revisionConflict }
            guard revision < Int64.max else { throw ServiceFailure.overloaded }
            let next = revision + 1
            try db.execute(sql: """
            INSERT INTO personalPolicy (principal, identity, revision, settings) VALUES (?, ?, ?, ?)
            ON CONFLICT(principal, identity) DO UPDATE SET
                revision = excluded.revision, settings = excluded.settings
            """, arguments: [
                account.principalID.rawValue,
                account.selfID.rawValue,
                next,
                bytes
            ])
            return AccountPolicy(revision: String(next), settings: settings)
        }
    }

    func forgetPolicy(for account: AccountRecord) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM personalPolicy WHERE principal = ? AND identity = ?",
                arguments: [account.principalID.rawValue, account.selfID.rawValue]
            )
        }
    }

    private static func policy(for account: AccountRecord, in db: Database) throws -> AccountPolicy {
        guard let row = try Row
            .fetchOne(
                db,
                sql: "SELECT revision, settings FROM personalPolicy WHERE principal = ? AND identity = ?",
                arguments: [account.principalID.rawValue, account.selfID.rawValue]
            )
        else {
            return AccountPolicy(revision: "0", settings: .init())
        }
        return try AccountPolicy(
            revision: String(row["revision"] as Int64),
            settings: ServiceCodec.decode(
                NotificationSettings.self,
                from: row["settings"] as Data
            )
        )
    }
}
