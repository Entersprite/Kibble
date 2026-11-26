import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public extension SQLiteAccountRegistry {
    func defaultPolicy(for principal: ServicePrincipalID) throws -> AccountPolicy {
        try database.read { db in try Self.defaultPolicy(for: principal, in: db) }
    }

    func setDefaultPolicy(
        _ rule: NotificationRule, for principal: ServicePrincipalID, expectedRevision: String
    ) throws -> AccountPolicy {
        var settings = NotificationSettings()
        settings.setRule(rule, for: .global, at: retentionClock(), by: "shared-defaults")
        let bytes = try ServiceCodec.encode(settings)
        guard bytes.count <= 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        return try database.write { db in
            let previous = try Self.defaultPolicy(for: principal, in: db)
            guard previous.revision == expectedRevision, let revision = Int64(previous.revision)
            else { throw ServiceFailure.revisionConflict }
            guard revision < Int64.max else { throw ServiceFailure.overloaded }
            let next = revision + 1
            try db.execute(sql: """
            INSERT INTO defaultPolicy (principal, revision, settings) VALUES (?, ?, ?)
            ON CONFLICT(principal) DO UPDATE SET revision = excluded.revision, settings = excluded.settings
            """, arguments: [principal.rawValue, next, bytes])
            return AccountPolicy(revision: String(next), settings: settings)
        }
    }

    internal static func defaultPolicy(
        for principal: ServicePrincipalID,
        in db: Database
    ) throws -> AccountPolicy {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT revision, settings FROM defaultPolicy WHERE principal = ?",
            arguments: [principal.rawValue]
        ) else { return AccountPolicy(revision: "0", settings: .init()) }
        return try AccountPolicy(
            revision: String(row["revision"] as Int64),
            settings: ServiceCodec.decode(NotificationSettings.self, from: row["settings"] as Data)
        )
    }
}
