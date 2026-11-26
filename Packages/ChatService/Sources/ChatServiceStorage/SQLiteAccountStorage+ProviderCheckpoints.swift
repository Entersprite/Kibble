import ChatAPI
import ChatKit
import ChatPersistence
import ChatRules
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage: ServiceProviderCheckpointStorage {
    public func providerCheckpoint() throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM serviceProviderCheckpoint WHERE id = 1")
        }
    }

    public func appendProviderBatch(
        _ batch: ProviderEventBatch, canonicalEvents rawEvents: [ChatEvent]
    ) throws -> ServiceEventPage {
        guard !batch.id.isEmpty, batch.id.utf8.count <= 128, rawEvents.count <= 258,
              (batch.previousCheckpoint?.count ?? 0) <= 512 * 1024,
              (batch.checkpoint?.count ?? 0) <= 512 * 1024 else { throw ServiceFailure.frameTooLarge }
        let events = try canonicalProviderEvents(rawEvents)
        let encoded = try events.map(ServiceCodec.encode)
        guard encoded.reduce(0, { $0 + $1.count }) <= 2 * 1024 * 1024
        else { throw ServiceFailure.frameTooLarge }
        var known = Set<Message.ID>()
        for event in events {
            if case let .messageReceived(message) = event, try projection.message(message.id) != nil {
                known.insert(message.id)
            }
        }
        let alreadyKnown = known
        return try projection.apply(events.flatMap { SyncReducer.reduce($0).writes }, when: { db in
            try Self.validateProviderBatch(batch, in: db)
        }, committing: { db, accepted in
            guard accepted else {
                return try ServiceEventPage(
                    checkpoint: checkpoint(db),
                    snapshot: nil,
                    events: [],
                    hasMore: false
                )
            }
            return try commitProviderBatch(
                batch,
                events: events,
                encoded: encoded,
                known: alreadyKnown,
                in: db
            )
        })
    }

    private func commitProviderBatch(
        _ batch: ProviderEventBatch, events: [ChatEvent], encoded: [Data],
        known: Set<Message.ID>, in db: Database
    ) throws -> ServiceEventPage {
        var known = known
        var committed: [ServiceEvent] = []
        for (event, bytes) in zip(events, encoded) {
            let seen: Bool = if case let .messageReceived(message) = event {
                !known.insert(message.id).inserted
            } else {
                false
            }
            try Self.updateMediaCatalog(event, db: db)
            try Self.appendNotifications(event, live: batch.isLive, known: seen, db: db)
            let cursor = try appendProviderJournal(event: bytes, live: batch.isLive, db: db)
            committed.append(ServiceEvent(cursor: cursor, event: event, isLiveArrival: batch.isLive))
        }
        try db.execute(sql: """
        INSERT INTO serviceProviderCheckpoint (id, checkpoint, batchID) VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET checkpoint = excluded.checkpoint, batchID = excluded.batchID
        """, arguments: [batch.checkpoint, batch.id])
        try pruneRetention(db)
        return try ServiceEventPage(
            checkpoint: checkpoint(db),
            snapshot: nil,
            events: committed,
            hasMore: false
        )
    }

    private static func validateProviderBatch(_ batch: ProviderEventBatch, in db: Database) throws -> Bool {
        let stored = try Row.fetchOne(db, sql: "SELECT * FROM serviceProviderCheckpoint WHERE id = 1")
        let checkpoint = stored?["checkpoint"] as Data?
        if stored?["batchID"] as String? == batch.id {
            guard checkpoint == batch.checkpoint else { throw ServiceFailure.operationConflict }
            return false
        }
        guard checkpoint == batch.previousCheckpoint else { throw ServiceFailure.resynchronizationRequired }
        return true
    }

    private func appendProviderJournal(event: Data, live: Bool, db: Database) throws -> ServiceCursor {
        let current = try Self.sequence(db)
        guard current < Int64.max else { throw ServiceFailure.overloaded }
        let next = current + 1
        try db.execute(
            sql: "INSERT INTO serviceJournal (sequence, event, live, recordedAt) VALUES (?, ?, ?, ?)",
            arguments: [next, event, live, retentionInstant(db)]
        )
        try db.execute(sql: "UPDATE serviceMetadata SET sequence = ? WHERE id = 1", arguments: [next])
        try db.execute(
            sql: "DELETE FROM serviceJournal WHERE sequence <= ?",
            arguments: [next - Int64(retention)]
        )
        return try checkpoint(db)
    }
}
