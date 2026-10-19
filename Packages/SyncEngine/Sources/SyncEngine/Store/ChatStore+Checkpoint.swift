import ChatKit
import ChatRules
import Foundation
import GRDB

public extension ChatStore {
    /// Snapshot and an owner's checkpoint are read under one SQLite snapshot.
    /// Histories stay lazy; callers invalidate their previous history coverage.
    func readSnapshot<Value>(
        _ body: @Sendable (Database, [ChatEvent]) throws -> Value
    ) throws -> Value {
        try database.read { db in
            let members = try Self.fetchMembers(db)
            var events: [ChatEvent] = try [
                .conversationsChanged(Self.fetchStoredConversations(db)),
                .membersResolved(members),
                .connectionStateChanged(Self.fetchConnectionState(db))
            ]
            if let me = try Self.fetchMe(db), let member = members.first(where: { $0.id == me }) {
                events.append(.selfIdentified(member))
            }
            return try body(db, events)
        }
    }
}
