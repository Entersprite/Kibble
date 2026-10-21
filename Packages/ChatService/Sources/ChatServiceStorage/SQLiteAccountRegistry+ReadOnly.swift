import ChatAPI
import ChatService
import Foundation
import GRDB

public extension SQLiteAccountRegistry {
    /// Diagnostic access to an existing registry, without migration or recovery writes.
    static func readExistingAccounts(path: String) throws -> [AccountRecord] {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let reader = try DatabaseQueue(path: path, configuration: configuration)
        return try reader.read { db in
            try Data.fetchAll(db, sql: "SELECT record FROM connectedAccount ORDER BY id")
                .map { try ServiceCodec.decode(AccountRecord.self, from: $0) }
        }
    }
}
