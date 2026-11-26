import ChatAPI
import Foundation
import GRDB
import Testing
@testable import ChatService
@testable import ChatServiceStorage

struct ReadOnlyRegistryTests {
    @Test func readingALegacyRegistryDoesNotMigrateIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("registry.sqlite").path
        let account = AccountRecord(
            id: .init("fixture"),
            principalID: .init("owner"),
            selfID: .init("me"),
            label: "Fixture",
            credentialGeneration: "one"
        )
        let writer = try DatabaseQueue(path: path)
        try writer.write { db in
            try db.execute(sql: "CREATE TABLE connectedAccount (id TEXT PRIMARY KEY, record BLOB NOT NULL)")
            try db.execute(
                sql: "INSERT INTO connectedAccount VALUES (?, ?)",
                arguments: [account.id.rawValue, ServiceCodec.encode(account)]
            )
            try db.execute(sql: "PRAGMA user_version = 7")
        }
        #expect(try SQLiteAccountRegistry.readExistingAccounts(path: path) == [account])
        let schema = try writer.read { db in
            try (
                Int.fetchOne(db, sql: "PRAGMA user_version"),
                String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            )
        }
        #expect(schema.0 == 7)
        #expect(schema.1 == ["connectedAccount"])
    }

    @Test func aMissingRegistryIsNeverCreated() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(throws: (any Error).self) { try SQLiteAccountRegistry.readExistingAccounts(path: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
