import ChatKit
import ChatRules
import Foundation
import GRDB

public extension ChatStore {
    /// Applied after the server answers, so removal during an in-flight
    /// search and a deletion from a previous app session are both honored.
    func searchableMessages(_ messages: [Message]) throws -> [Message] {
        try database.read { db in
            let states = try Row.fetchAll(
                db,
                sql: "SELECT id, isRemoved, historyClearedBefore FROM conversationActionState"
            )
            let removed = Set(states.filter { $0["isRemoved"] as Bool }.map { $0["id"] as String })
            let cutoffs = Dictionary(uniqueKeysWithValues: states.compactMap { row -> (String, Double)? in
                guard let cutoff: Double = row["historyClearedBefore"] else { return nil }
                return (row["id"], cutoff)
            })
            return messages.filter {
                !removed.contains($0.conversationID.rawValue)
                    && StoredDate.value($0.createdAt) > (cutoffs[$0.conversationID.rawValue] ?? -.infinity)
            }
        }
    }
}
