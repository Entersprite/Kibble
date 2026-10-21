import ChatKit
import Foundation
import GRDB

public extension ChatStore {
    func resourceSyncStatuses() throws -> [ResourceSyncStatus] {
        try database.read(Self.fetchResourceSyncStatuses)
    }

    func observeResourceSyncStatuses() -> AsyncValueObservation<[ResourceSyncStatus]> {
        ValueObservation.tracking(Self.fetchResourceSyncStatuses)
            .removeDuplicates().snapshotValues(in: database)
    }
}

extension ChatStore {
    static func fetchResourceSyncStatuses(_ db: Database) throws -> [ResourceSyncStatus] {
        try String.fetchAll(db, sql: "SELECT value FROM resourceSync ORDER BY key")
            .map { try Wire.value(ResourceSyncStatus.self, from: $0) }
    }

    static func setResourceSyncStatus(_ status: ResourceSyncStatus, in db: Database) throws {
        let key = try Wire.json([status.resource.rawValue, status.conversationID?.rawValue])
        if status.phase == .ready {
            try db.execute(sql: "DELETE FROM resourceSync WHERE key = ?", arguments: [key])
        } else {
            let value = try Wire.json(status)
            try db.execute(sql: """
            INSERT INTO resourceSync (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value WHERE value <> excluded.value
            """, arguments: [key, value])
        }
    }
}
