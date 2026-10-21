import ChatKit
import ChatRules
import Foundation
import GRDB

public extension ChatStore {
    /// Snapshot and an owner's checkpoint are read under one SQLite snapshot.
    /// Histories stay lazy; callers invalidate their previous history coverage.
    func readSnapshot<Value>(
        includingHistory: Set<Conversation.ID> = [],
        _ body: @Sendable (Database, [ChatEvent]) throws -> Value
    ) throws -> Value {
        try database.read { db in
            let members = try Self.fetchMembers(db)
            var events: [ChatEvent] = try [
                .conversationsChanged(Self.fetchStoredConversations(db)),
                .membersResolved(members),
                .connectionStateChanged(Self.fetchConnectionState(db))
            ]
            events += try Self.fetchResourceSyncStatuses(db).map(ChatEvent.resourceSyncChanged)
            if let me = try Self.fetchMe(db), let member = members.first(where: { $0.id == me }) {
                events.append(.selfIdentified(member))
            }
            var budget = 2 * 1024 * 1024
            let visible = try Set(Self.fetchStoredConversations(db).map(\.id))
            for id in includingHistory.intersection(visible).sorted(by: { $0.rawValue < $1.rawValue }) {
                let rows = try MessageRow.currentHistory.filter(Column("conversationID") == id.rawValue)
                    .order(Column("createdAt").desc, Column("id").desc).limit(200)
                    .fetchAll(db).reversed().map { try $0.message }
                let history = try ChatEvent.historyLoaded(MessageHistoryUpdate(
                    messages: rows,
                    conversationID: id
                ))
                let size = try Wire.json(history).utf8.count
                if size <= budget {
                    events.append(history)
                    budget -= size
                }
            }
            return try body(db, events)
        }
    }
}
