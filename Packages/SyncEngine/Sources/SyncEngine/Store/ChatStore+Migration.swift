import ChatKit
import Foundation
import GRDB

public extension ChatStore {
    /// Copies a quiescent legacy database through SQLite's backup API, including
    /// committed WAL pages. The source is read-only and never migrated or erased.
    static func copyLegacyDatabase(from source: URL, to destination: URL, identity: Member.ID) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: source.path, configuration: configuration)
        try reader.read { db in
            let owner = try Self.fetchMe(db)
            if owner == identity {
                return
            }
            let empty = try ["conversation", "message", "member"].allSatisfy { table in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) LIMIT 1)") == false
            }
            guard owner == nil, empty else { throw CocoaError(.fileReadCorruptFile) }
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: temporary.path + suffix)
            }
        }
        try backupLegacy(reader, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func backupLegacy(_ reader: DatabaseQueue, to temporary: URL) throws {
        let writer = try DatabaseQueue(path: temporary.path)
        try reader.backup(to: writer)
        try writer.read { db in
            guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"] else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try writer.close()
    }
}
