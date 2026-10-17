import ChatKit
import Foundation
import GRDB

extension ChatStore {
    /// Occurrences are ordered by their schedule; a late message stays in its
    /// original occurrence. Only the bounded result rows are decoded.
    func observeMeetingTranscript(
        occurrences: [Conversation.ID], request: TranscriptWindowRequest
    ) -> AsyncValueObservation<TranscriptWindow> {
        ValueObservation.tracking { [decodedTranscriptCache] db in
            try Self.meetingTranscript(
                occurrences: occurrences, request: request, cache: decodedTranscriptCache, db: db
            )
        }.removeDuplicates().snapshotValues(in: database)
    }

    func meetingTranscript(
        occurrences: [Conversation.ID], request: TranscriptWindowRequest
    ) async throws -> TranscriptWindow {
        try await database.read { [decodedTranscriptCache] db in
            try Self.meetingTranscript(
                occurrences: occurrences, request: request, cache: decodedTranscriptCache, db: db
            )
        }
    }

    private static func meetingTranscript(
        occurrences: [Conversation.ID], request: TranscriptWindowRequest,
        cache: DecodedTranscriptCache, db: Database
    ) throws -> TranscriptWindow {
        let query = MeetingTranscriptQuery(occurrences: occurrences)
        guard !occurrences.isEmpty else {
            return TranscriptWindow(messages: [], hasOlder: false, hasNewer: false)
        }
        let rows = try query.rows(request: request, db: db)
        let messages = try rows.map { try cache.decode($0) }
        guard let first = messages.first, let last = messages.last else {
            return TranscriptWindow(messages: [], hasOlder: false, hasNewer: false)
        }
        return try TranscriptWindow(
            messages: messages,
            hasOlder: query.exists(before: TranscriptCursor(first), db: db),
            hasNewer: query.exists(after: TranscriptCursor(last), db: db)
        )
    }
}

private struct MeetingTranscriptQuery {
    let occurrences: [Conversation.ID]

    private var prefix: String {
        let placeholders = occurrences.map { _ in "(?, ?)" }.joined(separator: ",")
        return """
        WITH occurrences(id, position) AS (VALUES \(placeholders))
        SELECT message.* FROM message JOIN occurrences ON occurrences.id = message.conversationID
        WHERE message.isReply = 0
        """
    }

    private var arguments: [DatabaseValue] {
        occurrences.enumerated().flatMap { [$0.element.rawValue.databaseValue, $0.offset.databaseValue] }
    }

    private func boundary(_ cursor: TranscriptCursor, comparison: String) -> (String, [DatabaseValue]) {
        guard let ordinal = occurrences.firstIndex(of: cursor.conversation) else { return ("0", []) }
        return (
            "(occurrences.position, message.createdAt, message.id) \(comparison) (?, ?, ?)",
            [
                ordinal.databaseValue,
                StoredDate.value(cursor.date).databaseValue,
                cursor.id.rawValue.databaseValue
            ]
        )
    }

    func exists(before cursor: TranscriptCursor, db: Database) throws -> Bool {
        try !fetch(condition: boundary(cursor, comparison: "<"), ascending: false, limit: 1, db: db).isEmpty
    }

    func exists(after cursor: TranscriptCursor, db: Database) throws -> Bool {
        try !fetch(condition: boundary(cursor, comparison: ">"), ascending: true, limit: 1, db: db).isEmpty
    }

    func rows(request: TranscriptWindowRequest, db: Database) throws -> [MessageRow] {
        switch request {
        case let .latest(limit):
            return try fetch(ascending: false, limit: limit, db: db).reversed()
        case let .tail(cursor, limit):
            return try fetch(
                condition: boundary(cursor, comparison: ">="),
                ascending: false,
                limit: limit,
                db: db
            )
            .reversed()
        case let .ending(cursor, limit):
            return try fetch(
                condition: boundary(cursor, comparison: "<="),
                ascending: false,
                limit: limit,
                db: db
            )
            .reversed()
        case let .starting(cursor, limit):
            return try fetch(
                condition: boundary(cursor, comparison: ">="),
                ascending: true,
                limit: limit,
                db: db
            )
        case let .between(lower, upper, limit):
            let low = boundary(lower, comparison: ">=")
            let high = boundary(upper, comparison: "<=")
            return try fetch(
                condition: ("\(low.0) AND \(high.0)", low.1 + high.1), ascending: false, limit: limit, db: db
            ).reversed()
        case let .around(id, limit):
            guard let row = try MessageRow.fetchOne(db, key: id.rawValue),
                  occurrences.contains(Conversation.ID(row.conversationID)), !row.isReply else {
                return try rows(request: .latest(limit), db: db)
            }
            let count = min(500, max(2, limit))
            let cursor = try TranscriptCursor(row.message)
            let older = try fetch(
                condition: boundary(cursor, comparison: "<="), ascending: false, limit: count / 2 + 1, db: db
            ).reversed()
            let newer = try fetch(
                condition: boundary(cursor, comparison: ">"), ascending: true, limit: count / 2 - 1, db: db
            )
            return Array(older) + newer
        }
    }

    private func fetch(
        condition: (String, [DatabaseValue]) = ("1", []), ascending: Bool, limit: Int, db: Database
    ) throws -> [MessageRow] {
        let order = ascending ? "ASC" : "DESC"
        return try MessageRow.fetchAll(
            db,
            sql: """
            \(prefix) AND (\(condition.0))
            ORDER BY occurrences.position \(order), message.createdAt \(order), message.id \(order) LIMIT ?
            """,
            arguments: StatementArguments(arguments + condition.1 + [min(500, max(1, limit)).databaseValue])
        )
    }
}
