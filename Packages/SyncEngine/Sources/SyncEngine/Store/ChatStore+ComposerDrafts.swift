import ChatKit
import Foundation
import GRDB

public extension ChatStore {
    func composerDrafts() throws -> [ComposerSnapshot] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM composerDraft").map {
                try JSONDecoder().decode(ComposerSnapshot.self, from: $0)
            }
        }
    }

    /// Replaces a complete client-owned snapshot atomically. It never touches
    /// messages or the service journal and erases with this account's replica.
    func saveComposerDrafts(_ drafts: [ComposerSnapshot]) throws {
        guard drafts.count <= 256 else {
            throw ChatError.unknown("Too many saved drafts")
        }
        let payloads = try drafts.map { try JSONEncoder().encode($0) }
        guard payloads.allSatisfy({ $0.count <= 1_048_576 }),
              payloads.reduce(0, { $0 + $1.count }) <= 8_388_608 else {
            throw ChatError.unknown("Saved drafts exceed the storage limit")
        }
        try database.write { db in
            try db.execute(sql: "DELETE FROM composerDraft")
            for payload in payloads {
                try db.execute(sql: "INSERT INTO composerDraft (payload) VALUES (?)", arguments: [payload])
            }
        }
    }
}
