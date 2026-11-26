import ChatAPI
import ChatService
import Foundation
import GRDB

extension SQLiteAccountRegistry {
    static func addLifecycleMigration(to migrations: inout DatabaseMigrator) {
        migrations.registerMigration("accountRegistry5") { db in
            try db.execute(sql: """
            CREATE TABLE registryLifecycle (
                id INTEGER PRIMARY KEY CHECK(id = 1), removalRevision INTEGER NOT NULL
            );
            INSERT INTO registryLifecycle (id, removalRevision) VALUES (1, 0);
            CREATE TABLE retiredIdentity (
                principal TEXT NOT NULL, identity TEXT NOT NULL, account TEXT NOT NULL,
                revision INTEGER NOT NULL, PRIMARY KEY(principal, identity)
            );
            """)
        }
    }

    public func removalRevision() throws -> String {
        try database.read { db in try String(Self.removalRevision(in: db)) }
    }

    public func validateLinkAdmission(_ link: AccountLinkRecord) throws {
        try database.read { db in try Self.validateLinkAdmission(link, in: db) }
    }

    static func validateLinkAdmission(_ link: AccountLinkRecord, in db: Database) throws {
        guard let identity = link.selfID, let admitted = Int64(link.removalRevision ?? "0"),
              admitted >= 0 else {
            throw ServiceFailure.invalidRequest
        }
        let retired = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM retiredIdentity WHERE principal = ? AND identity = ?",
            arguments: [link.principalID.rawValue, identity.rawValue]
        ) ?? 0
        guard admitted >= retired else { throw ServiceFailure.staleAccount }
    }

    static func markRetiring(_ account: AccountRecord, in db: Database) throws {
        let previous = try String.fetchOne(
            db,
            sql: "SELECT account FROM retiredIdentity WHERE principal = ? AND identity = ?",
            arguments: [account.principalID.rawValue, account.selfID.rawValue]
        )
        guard previous != account.id.rawValue else { return }
        let current = try removalRevision(in: db)
        guard current < Int64.max else { throw ServiceFailure.overloaded }
        let next = current + 1
        try db.execute(
            sql: "UPDATE registryLifecycle SET removalRevision = ? WHERE id = 1",
            arguments: [next]
        )
        try db.execute(sql: """
        INSERT INTO retiredIdentity (principal, identity, account, revision) VALUES (?, ?, ?, ?)
        ON CONFLICT(principal, identity) DO UPDATE
        SET account = excluded.account, revision = excluded.revision
        """, arguments: [account.principalID.rawValue, account.selfID.rawValue, account.id.rawValue, next])
    }

    private static func removalRevision(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT removalRevision FROM registryLifecycle WHERE id = 1") ?? 0
    }
}
