import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public final class SQLiteAccountRegistry: AccountLinkRegistry, AccountPolicyStore, AccountLinkHistoryStore,
    Sendable {
    let database: DatabaseQueue
    let linkRetention: AccountRetentionLimits
    let retentionClock: @Sendable () -> Date

    public init(
        path: String, linkRetention: AccountRetentionLimits = AccountRetentionLimits(),
        retentionClock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.linkRetention = linkRetention; self.retentionClock = retentionClock
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path, configuration: configuration)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("accountRegistry1") { db in
            try db.create(table: "connectedAccount") { table in
                table.column("id", .text).primaryKey()
                table.column("principal", .text).notNull()
                table.column("identity", .text).notNull()
                table.column("record", .blob).notNull()
                table.uniqueKey(["principal", "identity"])
            }
        }
        migrations.registerMigration("accountRegistry2") { db in
            try db.create(table: "retiredAccount") { table in
                table.column("id", .text).primaryKey()
            }
        }
        migrations.registerMigration("accountRegistry3") { db in
            try db.create(table: "accountLink") { table in
                table.column("id", .text).primaryKey()
                table.column("principal", .text).notNull()
                table.column("device", .text).notNull()
                table.column("operation", .text).notNull()
                table.column("record", .blob).notNull()
                table.uniqueKey(["principal", "device", "operation"])
            }
        }
        migrations.registerMigration("accountRegistry4") { db in
            try db.create(table: "personalPolicy") { table in
                table.column("principal", .text).notNull()
                table.column("identity", .text).notNull()
                table.column("revision", .integer).notNull()
                table.column("settings", .blob).notNull()
                table.primaryKey(["principal", "identity"])
            }
        }
        Self.addLifecycleMigration(to: &migrations)
        Self.addLinkHistoryMigration(to: &migrations)
        try migrations.migrate(database)
    }

    public func accounts() throws -> [AccountRecord] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM connectedAccount ORDER BY id")
                .map { try ServiceCodec.decode(AccountRecord.self, from: $0) }
        }
    }

    public func save(_ account: AccountRecord) throws {
        try database.write { db in try Self.save(account, in: db) }
    }

    private static func save(_ account: AccountRecord, in db: Database) throws {
        let bytes = try ServiceCodec.encode(account)
        let retired = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM retiredAccount WHERE id = ?)",
            arguments: [account.id.rawValue]
        ) ?? false
        guard !retired else {
            throw ServiceFailure.operationConflict
        }
        try db.execute(sql: """
        INSERT INTO connectedAccount (id, principal, identity, record) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET record = excluded.record
        WHERE principal = excluded.principal AND identity = excluded.identity
        """, arguments: [
            account.id.rawValue,
            account.principalID.rawValue,
            account.selfID.rawValue,
            bytes
        ])
        guard db.changesCount == 1 else { throw ServiceFailure.operationConflict }
        if account.isRemoving {
            try Self.markRetiring(account, in: db)
        }
    }

    public func remove(_ account: ConnectedAccountID) throws {
        try database.write { db in
            if let data = try Data.fetchOne(
                db,
                sql: "SELECT record FROM connectedAccount WHERE id = ?",
                arguments: [account.rawValue]
            ) {
                try Self.markRetiring(ServiceCodec.decode(AccountRecord.self, from: data), in: db)
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO retiredAccount (id) VALUES (?)",
                arguments: [account.rawValue]
            )
            try db.execute(sql: "DELETE FROM connectedAccount WHERE id = ?", arguments: [account.rawValue])
        }
    }

    public func links() throws -> [AccountLinkRecord] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM accountLink ORDER BY id")
                .map { try ServiceCodec.decode(AccountLinkRecord.self, from: $0) }
        }
    }

    public func saveLink(_ link: AccountLinkRecord) throws {
        try database.write { db in try Self.saveLink(link, in: db) }
    }

    private static func saveLink(_ link: AccountLinkRecord, in db: Database) throws {
        let bytes = try ServiceCodec.encode(link)
        guard bytes.count <= 16 * 1024 else { throw ServiceFailure.frameTooLarge }
        if let previous = try Self.link(link.id, in: db) {
            guard sameIntent(previous, link) else { throw ServiceFailure.operationConflict }
        }
        try db.execute(sql: """
        INSERT INTO accountLink (id, principal, device, operation, record, phase, bornAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            record = excluded.record, phase = excluded.phase, bornAt = excluded.bornAt
        """, arguments: [
            link.id.rawValue,
            link.principalID.rawValue,
            link.deviceID.rawValue,
            link.operationID.rawValue,
            bytes, link.phase, ClientOperationID.createdAt(link.operationID.rawValue)?.timeIntervalSince1970
        ])
    }

    private static func link(_ id: AccountLinkID, in db: Database) throws -> AccountLinkRecord? {
        try Data.fetchOne(db, sql: "SELECT record FROM accountLink WHERE id = ?", arguments: [id.rawValue])
            .map { try ServiceCodec.decode(AccountLinkRecord.self, from: $0) }
    }

    private static func sameIntent(_ lhs: AccountLinkRecord, _ rhs: AccountLinkRecord) -> Bool {
        lhs.id == rhs.id && lhs.principalID == rhs.principalID && lhs.deviceID == rhs.deviceID &&
            lhs.operationID == rhs.operationID && lhs.accountID == rhs.accountID &&
            lhs.targetAccountID == rhs.targetAccountID && lhs.generation == rhs.generation &&
            lhs.previousGeneration == rhs.previousGeneration && lhs.expiresAt == rhs.expiresAt &&
            lhs.removalRevision == rhs.removalRevision
    }

    public func commitLink(_ link: AccountLinkRecord, account: AccountRecord) throws {
        try database.write { db in
            guard let saved = try Self.link(link.id, in: db), saved.phase == "installing",
                  Self.sameIntent(saved, link), saved.selfID == account.selfID,
                  link.accountID == account.id, link.principalID == account.principalID,
                  link.generation == account.credentialGeneration
            else { throw ServiceFailure.operationConflict }
            let current = try Data.fetchOne(
                db,
                sql: "SELECT record FROM connectedAccount WHERE id = ?",
                arguments: [account.id.rawValue]
            )
            .map { try ServiceCodec.decode(AccountRecord.self, from: $0) }
            if link.targetAccountID != nil {
                guard let current, !current.isRemoving,
                      current.authenticationState == nil || current.authenticationState == "required",
                      current.credentialGeneration == link.previousGeneration,
                      current.selfID == account.selfID else { throw ServiceFailure.revisionConflict }
            } else {
                guard current == nil else { throw ServiceFailure.operationConflict }
            }
            try Self.validateLinkAdmission(link, in: db)
            try Self.save(account, in: db)
            var committed = link
            committed.phase = "committed"
            try Self.saveLink(committed, in: db)
        }
    }
}
