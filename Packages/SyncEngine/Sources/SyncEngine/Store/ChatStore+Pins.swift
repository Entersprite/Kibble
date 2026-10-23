import ChatKit
import Foundation
import GRDB

/// Saved display state. Write authority must be renewed by a live query.
public struct CachedMessagePins: Equatable, Sendable {
    public let pins: PinnedMessages?
    public let revision: Int64
}

extension ChatStore {
    static func replaceMessagePins(
        _ pins: PinnedMessages,
        in conversation: Conversation.ID,
        db: Database
    ) throws {
        guard pins.messages.count <= 100, pins.members.count <= 512,
              Set(pins.messages.map(\.id)).count == pins.messages.count,
              pins.messages.allSatisfy({ $0.conversationID == conversation && !$0.isDeleted })
        else { throw ChatError.decoding("Invalid pinned message snapshot.") }
        var saved = pins
        saved.canModify = false
        let value = try Wire.json(saved)
        guard value.utf8.count <= 2 * 1024 * 1024 else {
            throw ChatError.decoding("Pinned message snapshot is too large.")
        }
        try db.execute(sql: """
        INSERT INTO messagePins(conversationID, value)
        SELECT ?, ? WHERE EXISTS (SELECT 1 FROM conversation WHERE id = ?)
        ON CONFLICT(conversationID) DO UPDATE SET value = excluded.value
        WHERE value <> excluded.value
        """, arguments: [conversation.rawValue, value, conversation.rawValue])
    }

    static func fetchMessagePins(_ db: Database, in conversation: Conversation.ID) throws -> PinnedMessages? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM messagePins WHERE conversationID = ?",
            arguments: [conversation.rawValue]
        )
        .map { try Wire.value(PinnedMessages.self, from: $0) }
    }

    static func invalidateMessagePins(_ conversation: Conversation.ID, in db: Database) throws {
        try db.execute(sql: """
        INSERT INTO messagePinRevision(conversationID, revision)
        SELECT ?, 1 WHERE EXISTS (SELECT 1 FROM conversation WHERE id = ?)
        ON CONFLICT(conversationID) DO UPDATE SET revision =
            CASE WHEN revision = 9223372036854775807 THEN 0 ELSE revision + 1 END
        """, arguments: [conversation.rawValue, conversation.rawValue])
    }
}

public extension ChatStore {
    func cachedMessagePins(in conversation: Conversation.ID) throws -> PinnedMessages? {
        try database.read { try Self.fetchMessagePins($0, in: conversation) }
    }

    func observeMessagePins(in conversation: Conversation.ID) -> AsyncValueObservation<CachedMessagePins> {
        ValueObservation.tracking { db in
            try CachedMessagePins(
                pins: Self.fetchMessagePins(db, in: conversation),
                revision: Int64.fetchOne(
                    db,
                    sql: "SELECT revision FROM messagePinRevision WHERE conversationID = ?",
                    arguments: [conversation.rawValue]
                ) ?? 0
            )
        }.removeDuplicates().snapshotValues(in: database)
    }

    /// The store forwards committed invalidations; pin membership is queried separately.
    func observeMessagePinRevision(in conversation: Conversation.ID) -> AsyncValueObservation<Int64> {
        ValueObservation.tracking { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM messagePinRevision WHERE conversationID = ?",
                arguments: [conversation.rawValue]
            ) ?? 0
        }.removeDuplicates().snapshotValues(in: database)
    }
}

extension ChatStore {
    static func appendPinSnapshots(
        _ db: Database, to events: inout [ChatEvent], budget: inout Int,
        preferred: Set<Conversation.ID>
    ) throws {
        for conversation in preferred.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let pins = try fetchMessagePins(db, in: conversation) else { continue }
            let event = ChatEvent.messagePinsLoaded(conversationID: conversation, pins: pins)
            let size = try Wire.json(event).utf8.count
            if size <= budget {
                events.append(event)
                budget -= size
            }
        }
    }
}
