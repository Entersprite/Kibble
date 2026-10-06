import ChatKit
import Foundation
import GRDB

/// Who the composer's `@` list offers (mention composer spec §3.3).
extension ChatStore {
    func mentionCandidates(in conversation: Conversation.ID) throws -> [Member] {
        try database.read { db in try Self.fetchMentionCandidates(conversation, db) }
    }

    func observeMentionCandidates(in conversation: Conversation.ID) -> AsyncValueObservation<[Member]> {
        ValueObservation
            .tracking { db in try Self.fetchMentionCandidates(conversation, db) }
            .values(in: database)
    }

    /// The conversation's members, or, while it lists nobody, the people who
    /// have posted in it. You, apps and anyone without a name are left out:
    /// a pick inserts the name, so a nameless row cannot be picked. Recent
    /// senders first, newest first; then everyone else by name.
    static func fetchMentionCandidates(_ conversation: Conversation.ID, _ db: Database) throws -> [Member] {
        let recent = try String.fetchAll(
            db,
            sql: """
            SELECT sender FROM message WHERE conversationID = ?
            GROUP BY sender ORDER BY MAX(createdAt) DESC
            """,
            arguments: [conversation.rawValue]
        )
        var ids = try String.fetchAll(
            db,
            sql: "SELECT memberID FROM conversationMember WHERE conversationID = ? ORDER BY position",
            arguments: [conversation.rawValue]
        )
        if ids.isEmpty {
            ids = recent
        }
        let me = try fetchMe(db)
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let members = try MemberRow.filter(keys: ids).fetchAll(db)
            .map { try $0.member }
            .filter { $0.kind == .human && $0.id != me && !($0.displayName ?? "").isEmpty }
        return members.sorted { lhs, rhs in
            switch (rank[lhs.id.rawValue], rank[rhs.id.rawValue]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil):
                (lhs.displayName ?? "").localizedStandardCompare(rhs.displayName ?? "") == .orderedAscending
            }
        }
    }
}
