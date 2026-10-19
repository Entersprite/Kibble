import ChatKit
import ChatRules
import Foundation
import GRDB

package struct TranscriptCursor: Equatable, Sendable {
    package var conversation: Conversation.ID
    package var date: Date
    package var id: Message.ID

    package init(_ message: Message) {
        conversation = message.conversationID
        date = message.createdAt
        id = message.id
    }
}

package enum TranscriptWindowRequest: Sendable {
    case latest(Int)
    case tail(TranscriptCursor, Int)
    case ending(TranscriptCursor, Int)
    case starting(TranscriptCursor, Int)
    case around(Message.ID, Int)
    case between(TranscriptCursor, TranscriptCursor, Int)
}

package struct TranscriptWindow: Equatable, Sendable {
    package var messages: [Message]
    package var hasOlder: Bool
    package var hasNewer: Bool
}

package extension ChatStore {
    func observeTranscriptWindow(
        in conversation: Conversation.ID, request: TranscriptWindowRequest
    ) -> AsyncValueObservation<TranscriptWindow> {
        ValueObservation.tracking { [decodedTranscriptCache] db in
            try Self.fetchTranscriptWindow(
                in: conversation,
                request: request,
                cache: decodedTranscriptCache,
                db: db
            )
        }.removeDuplicates().snapshotValues(in: database)
    }

    func transcriptWindow(
        in conversation: Conversation.ID, request: TranscriptWindowRequest
    ) async throws -> TranscriptWindow {
        try await database.read { [decodedTranscriptCache] db in
            try Self.fetchTranscriptWindow(
                in: conversation,
                request: request,
                cache: decodedTranscriptCache,
                db: db
            )
        }
    }

    /// Streams only scalar candidate IDs before decoding at most six rows.
    /// Checked IDs stay a set here rather than a growing SQLite bind list.
    func cachedMissingRootCandidates(
        in conversation: Conversation.ID, from oldest: Date, through newest: Date,
        excluding excluded: Set<Message.ID>, limit: Int = 6
    ) throws -> [Message] {
        try database.read { db in
            let cursor = try MessageRow
                .filter(Column("conversationID") == conversation.rawValue && Column("isReply") == false)
                .filter(Column("createdAt") >= StoredDate.value(oldest) && Column("createdAt") <= StoredDate
                    .value(newest))
                .order(Column("createdAt").desc, Column("id").desc)
                .select(Column("id"), as: String.self).fetchCursor(db)
            var ids: [String] = []
            while ids.count < limit, let id = try cursor.next() {
                if !id.hasPrefix("local/"), !excluded.contains(Message.ID(id)) {
                    ids.append(id)
                }
            }
            return try MessageRow.filter(keys: ids).order(Column("createdAt").asc, Column("id").asc)
                .fetchAll(db).map { try decodedTranscriptCache.decode($0) }
        }
    }

    internal static func fetchTranscriptWindow(
        in conversation: Conversation.ID, request: TranscriptWindowRequest,
        cache: DecodedTranscriptCache, db: Database
    ) throws -> TranscriptWindow {
        let base = MessageRow
            .filter(Column("conversationID") == conversation.rawValue && Column("isReply") == false)
        let rows = try fetchTranscriptRows(base: base, request: request, db: db)
        let messages = try rows.map { try cache.decode($0) }
        guard let first = messages.first, let last = messages.last else {
            return TranscriptWindow(messages: [], hasOlder: false, hasNewer: false)
        }
        let hasOlder = try base.filter(before(TranscriptCursor(first)) && Column("id") != first.id.rawValue)
            .select(Column("id"), as: String.self).fetchOne(db) != nil
        let hasNewer = try base.filter(after(TranscriptCursor(last)) && Column("id") != last.id.rawValue)
            .select(Column("id"), as: String.self).fetchOne(db) != nil
        return TranscriptWindow(messages: messages, hasOlder: hasOlder, hasNewer: hasNewer)
    }

    private static func before(_ cursor: TranscriptCursor) -> SQLExpression {
        Column("createdAt") < StoredDate.value(cursor.date)
            || (Column("createdAt") == StoredDate.value(cursor.date) && Column("id") <= cursor.id.rawValue)
    }

    private static func after(_ cursor: TranscriptCursor) -> SQLExpression {
        Column("createdAt") > StoredDate.value(cursor.date)
            || (Column("createdAt") == StoredDate.value(cursor.date) && Column("id") >= cursor.id.rawValue)
    }

    private static func fetchTranscriptRows(
        base: QueryInterfaceRequest<MessageRow>, request: TranscriptWindowRequest, db: Database
    ) throws -> [MessageRow] {
        var rows: [MessageRow]
        switch request {
        case let .latest(limit):
            rows = try base.order(Column("createdAt").desc, Column("id").desc).limit(min(500, limit))
                .fetchAll(db).reversed()
        case let .tail(cursor, limit):
            rows = try base.filter(after(cursor)).order(Column("createdAt").desc, Column("id").desc)
                .limit(min(500, limit)).fetchAll(db).reversed()
        case let .ending(cursor, limit):
            rows = try base.filter(before(cursor)).order(Column("createdAt").desc, Column("id").desc)
                .limit(min(500, limit)).fetchAll(db).reversed()
        case let .starting(cursor, limit):
            rows = try base.filter(after(cursor)).order(Column("createdAt").asc, Column("id").asc)
                .limit(min(500, limit)).fetchAll(db)
        case let .between(lower, upper, limit):
            rows = try base.filter(after(lower) && before(upper)).order(
                Column("createdAt").desc,
                Column("id").desc
            )
            .limit(min(500, limit)).fetchAll(db).reversed()
        case let .around(id, limit):
            guard let target = try base.filter(Column("id") == id.rawValue).fetchOne(db) else {
                return try fetchTranscriptRows(base: base, request: .latest(limit), db: db)
            }
            let cursor = try TranscriptCursor(target.message)
            let count = min(500, limit)
            let older = try base.filter(before(cursor)).order(Column("createdAt").desc, Column("id").desc)
                .limit(count / 2 + 1).fetchAll(db).reversed()
            let newer = try base.filter(after(cursor) && Column("id") != id.rawValue)
                .order(Column("createdAt").asc, Column("id").asc).limit(count / 2 - 1).fetchAll(db)
            rows = Array(older) + newer
        }
        return rows
    }
}
