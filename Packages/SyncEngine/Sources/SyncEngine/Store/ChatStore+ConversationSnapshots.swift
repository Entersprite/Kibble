import ChatKit
import ChatRules
import Foundation
import GRDB

package extension ChatStore {
    static func upsert(_ conversation: Conversation, in db: Database) throws {
        guard try mayRestoreConversation(conversation, in: db) else { return }
        var row = try ConversationRow(conversation)
        if let previous = try ConversationRow.fetchOne(db, key: row.id) {
            if let activity = previous.lastActivity {
                row.lastActivity = max(row.lastActivity ?? activity, activity)
            }
            // Reduced summaries omit detail metadata. Only an explicit metadata
            // event withdraws it; an ordinary refresh must preserve saved grouping.
            if try row.kind == (Wire.string(Conversation.Kind.meetChat)), row.kind == previous.kind,
               row.meeting == nil {
                row.meeting = previous.meeting
            }
        }
        // `lastReadAt` is `Conversation.readPosition` (the mentions-list spec
        // §1). A snapshot that carries one is authoritative: a world load's is
        // Google's current read state. One that carries none - a world item
        // with no `last_read_time`, a fixture's `conversationUpdated` - says
        // nothing about the position, so the value `.setReadState` recorded is
        // carried forward rather than overwritten with NULL.
        if row.lastReadAt == nil {
            row.lastReadAt = try Double.fetchOne(
                db,
                sql: "SELECT lastReadAt FROM conversation WHERE id = ?",
                arguments: [row.id]
            ).map(StoredDate.date)
        }
        if let previous = try Double.fetchOne(
            db,
            sql: """
            SELECT MAX(cutoff) FROM (
                SELECT historyClearedBefore AS cutoff FROM conversation WHERE id = ?
                UNION ALL SELECT historyClearedBefore AS cutoff FROM conversationActionState WHERE id = ?
            )
            """,
            arguments: [row.id, row.id]
        ) {
            let prior = StoredDate.date(previous)
            row.historyClearedBefore = max(row.historyClearedBefore ?? prior, prior)
        }
        if let cutoff = row.historyClearedBefore {
            try clearConversationHistory(conversation.id, through: cutoff, in: db)
        }
        if try ConversationRow.fetchOne(db, key: row.id) != row {
            try row.upsert(db)
        }
        try db.execute(
            sql: "UPDATE conversationActionState SET isRemoved = 0 WHERE id = ? AND isRemoved <> 0",
            arguments: [row.id]
        )
        // A snapshot that lists nobody says nothing about membership, the same
        // reasoning as `lastReadAt` above. A space's world item never lists
        // its members (`findings.md` §43.1); `list_members` does (§56.1), and
        // a later world load or `conversationUpdated` must not erase that.
        // Nobody is never the true answer: the signed-in account is always a
        // member of a conversation it can see. `.setMembership` still replaces
        // outright.
        if !conversation.members.isEmpty {
            try setMembership(conversation.id, conversation.members, in: db)
        }
    }

    static func setMembership(
        _ conversation: Conversation.ID,
        _ members: [Member.ID],
        in db: Database
    ) throws {
        // A directory answer can arrive after Hide, Block or Leave removed
        // this row. Keep the member records without restoring membership.
        if try !ConversationRow.exists(db, key: conversation.rawValue),
           try Bool.fetchOne(
               db,
               sql: "SELECT isRemoved FROM conversationActionState WHERE id = ?",
               arguments: [conversation.rawValue]
           ) == true {
            return
        }
        let existing = try String.fetchAll(
            db, sql: "SELECT memberID FROM conversationMember WHERE conversationID = ? ORDER BY position",
            arguments: [conversation.rawValue]
        )
        guard existing != members.map(\.rawValue) else { return }
        try MembershipRow
            .filter(Column("conversationID") == conversation.rawValue)
            .deleteAll(db)
        for (position, member) in members.enumerated() {
            try MembershipRow(
                conversationID: conversation.rawValue,
                memberID: member.rawValue,
                position: position
            ).insert(db)
        }
    }
}
