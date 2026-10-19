import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public final class SQLiteAccountRegistry: AccountRegistry, Sendable {
    private let database: DatabaseQueue

    public init(path: String) throws {
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
        try migrations.migrate(database)
    }

    public func accounts() throws -> [AccountRecord] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM connectedAccount ORDER BY id")
                .map { try ServiceCodec.decode(AccountRecord.self, from: $0) }
        }
    }

    public func save(_ account: AccountRecord) throws {
        let bytes = try ServiceCodec.encode(account)
        try database.write { db in
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
        }
    }

    public func remove(_ account: ConnectedAccountID) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO retiredAccount (id) VALUES (?)",
                arguments: [account.rawValue]
            )
            try db.execute(sql: "DELETE FROM connectedAccount WHERE id = ?", arguments: [account.rawValue])
        }
    }
}
