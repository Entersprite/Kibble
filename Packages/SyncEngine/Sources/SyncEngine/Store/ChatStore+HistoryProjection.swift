import ChatKit
import Foundation
import GRDB

public extension ChatStore {
    /// Bounded cached history for replica hydration. Includes replies as well
    /// as roots, without granting completeness to this time window.
    func recentHistory(in conversation: Conversation.ID, limit: Int) throws -> [Message] {
        try database.read { db in
            try MessageRow.filter(Column("conversationID") == conversation.rawValue)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(min(200, max(1, limit))).fetchAll(db).reversed().map { try $0.message }
        }
    }
}
