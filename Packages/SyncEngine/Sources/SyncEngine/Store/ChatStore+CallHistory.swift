import ChatKit
import Foundation
import GRDB

public extension ChatStore {
    /// Confirmed records already retained by this account. No provider fetch or
    /// new retention policy; erasure and history confidence use the same tables
    /// and rules as the transcript. Results are newest first, including replies.
    func callHistory(_ query: CallHistoryQuery = .init()) throws -> CallHistoryPage {
        let position = try CallHistoryPosition.decode(for: query)
        return try database.read { db in
            var conditions = [
                "callStatus IS NOT NULL", "isDeleted = 0",
                "NOT EXISTS (SELECT 1 FROM messageDelivery WHERE messageID = message.id)"
            ]
            var arguments = StatementArguments()
            if let conversation = query.conversationID {
                conditions.append("conversationID = ?")
                arguments += [conversation.rawValue]
            }
            if let position {
                conditions.append("(createdAt < ? OR (createdAt = ? AND id < ?))")
                arguments += [position.time, position.time, position.messageID]
            }
            arguments += [query.limit + 1]
            let rows = try MessageRow.fetchAll(db, sql: """
            SELECT message.* FROM currentMessage AS message
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY createdAt DESC, id DESC LIMIT ?
            """, arguments: arguments)
            let messages = try rows.prefix(query.limit).map { try $0.message }
            let next = rows.count > query.limit ? try messages.last.map {
                try CallHistoryPosition(message: $0, query: query).encoded()
            } : nil
            return CallHistoryPage(messages: messages, nextCursor: next)
        }
    }
}
