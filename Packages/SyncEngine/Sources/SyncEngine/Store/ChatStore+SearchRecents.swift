import ChatRules
import Foundation
import GRDB

/// Recent searches (search spec §1.2): what the overlay shows before anything
/// is typed. Written when a search opens a hit; read when the overlay opens,
/// never while it renders.
public extension ChatStore {
    static let searchRecentLimit = 10

    func recordSearch(_ text: String, at date: Date) throws {
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO searchRecent (text, usedAt) VALUES (?, ?)
                ON CONFLICT(text) DO UPDATE SET usedAt = excluded.usedAt
                """,
                arguments: [text, date.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                DELETE FROM searchRecent WHERE text NOT IN
                    (SELECT text FROM searchRecent ORDER BY usedAt DESC LIMIT ?)
                """,
                arguments: [Self.searchRecentLimit]
            )
        }
    }

    /// Newest first.
    func recentSearches(limit: Int) throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT text FROM searchRecent ORDER BY usedAt DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }
}
