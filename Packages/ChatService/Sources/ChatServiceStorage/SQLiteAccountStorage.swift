import ChatAPI
import ChatKit
import ChatPersistence
import ChatRules
import ChatService
import Foundation
import GRDB

public final class SQLiteAccountStorage: ServiceAccountStorage, Sendable {
    private let account: ConnectedAccountID
    let database: DatabaseQueue
    private let projection: ChatStore
    private let retention: Int

    public init(account: ConnectedAccountID, path: String, retention: Int = 4096) throws {
        self.account = account
        self.retention = max(1, retention)
        database = try DatabaseQueue(path: path)
        projection = try ChatStore(database)
        let stream = UUID().uuidString
        try database.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS serviceMetadata (
                id INTEGER PRIMARY KEY CHECK(id = 1), version INTEGER NOT NULL,
                stream TEXT NOT NULL, sequence INTEGER NOT NULL DEFAULT 0,
                policyRevision INTEGER NOT NULL DEFAULT 0, policy BLOB
            );
            INSERT OR IGNORE INTO serviceMetadata (id, version, stream) VALUES (1, 1, ?);
            """, arguments: [stream])
            guard try Int.fetchOne(db, sql: "SELECT version FROM serviceMetadata WHERE id = 1") == 1 else {
                throw ServiceFailure.incompatibleVersion
            }
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS serviceJournal (
                sequence INTEGER PRIMARY KEY, event BLOB NOT NULL, live INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS serviceOperation (
                id TEXT PRIMARY KEY, request BLOB NOT NULL, value BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS serviceUploadReference (
                id TEXT NOT NULL, conversationID TEXT NOT NULL, value BLOB NOT NULL, expiresAt REAL NOT NULL,
                PRIMARY KEY(id, conversationID)
            );
            CREATE INDEX IF NOT EXISTS serviceUploadReferenceExpiry ON serviceUploadReference(expiresAt);
            """)
            // A crash after dispatch is ambiguous. Never automatically dispatch it again.
            let rows = try Row.fetchAll(db, sql: "SELECT id, value FROM serviceOperation")
            for row in rows {
                let previous = try ServiceCodec.decode(ServiceOperation.self, from: row["value"] as Data)
                if previous.state == "dispatching" {
                    let value = ServiceOperation(id: previous.id, state: "unknown")
                    try db.execute(
                        sql: "UPDATE serviceOperation SET value = ? WHERE id = ?",
                        arguments: [ServiceCodec.encode(value), previous.id.rawValue]
                    )
                }
            }
        }
        try projection.apply([.clearEphemeralState])
    }

    public func checkpoint() throws -> ServiceCursor {
        try database.read { db in try checkpoint(db) }
    }

    public func recentHistory(in conversation: Conversation.ID, limit: Int) throws -> [Message] {
        try projection.recentHistory(in: conversation, limit: limit)
    }

    public func conversations() throws -> [Conversation] {
        try projection.conversations()
    }

    public func conversation(_ id: Conversation.ID) throws -> Conversation? {
        try projection.conversation(id)
    }

    public func append(_ event: ChatEvent, live: Bool) throws -> ServiceCursor {
        let bytes = try ServiceCodec.encode(event)
        guard bytes.count <= 2 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        return try projection.apply(SyncReducer.reduce(event).writes) { db in
            let current = try Self.sequence(db)
            guard current < Int64.max else { throw ServiceFailure.overloaded }
            let next = current + 1
            try db.execute(
                sql: "INSERT INTO serviceJournal (sequence, event, live) VALUES (?, ?, ?)",
                arguments: [next, bytes, live]
            )
            try db.execute(sql: "UPDATE serviceMetadata SET sequence = ? WHERE id = 1", arguments: [next])
            try db.execute(
                sql: "DELETE FROM serviceJournal WHERE sequence <= ?",
                arguments: [next - Int64(retention)]
            )
            return try checkpoint(db)
        }
    }

    public func readEvents(after cursor: ServiceCursor?, limit: Int) throws -> ServiceEventPage {
        let limit = min(256, max(1, limit))
        return try projection.readSnapshot { db, snapshot in
            let end = try checkpoint(db)
            let first = try Int64
                .fetchOne(db, sql: "SELECT MIN(sequence) FROM serviceJournal") ?? (Int64(end.sequence) + 1)
            guard let cursor, cursor.accountID == account, cursor.streamID == end.streamID,
                  cursor.sequence <= end.sequence, cursor.sequence >= UInt64(max(0, first - 1)) else {
                return ServiceEventPage(checkpoint: end, snapshot: snapshot, events: [], hasMore: false)
            }
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT * FROM serviceJournal WHERE sequence > ? ORDER BY sequence LIMIT ?",
                arguments: [Int64(cursor.sequence), limit]
            )
            var events: [ServiceEvent] = []
            var bytes = 0
            while let row = try rows.next() {
                let eventBytes = row["event"] as Data
                if !events.isEmpty, bytes + eventBytes.count > 2 * 1024 * 1024 {
                    break
                }
                bytes += eventBytes.count
                try events.append(ServiceEvent(
                    cursor: ServiceCursor(
                        accountID: account,
                        streamID: end.streamID,
                        sequence: UInt64(row["sequence"] as Int64)
                    ),
                    event: ServiceCodec.decode(ChatEvent.self, from: eventBytes),
                    // Replaying to a client cannot create a new host notification.
                    isLiveArrival: false
                ))
            }
            let delivered = events.last?.cursor ?? cursor
            return ServiceEventPage(
                checkpoint: delivered,
                snapshot: nil,
                events: events,
                hasMore: delivered.sequence < end.sequence
            )
        }
    }

    public func operation(_ id: ServiceOperationID) throws -> ServiceOperation? {
        try database.read { db in try Self.operation(id, db) }
    }

    public func reserve(_ id: ServiceOperationID, request: ServiceRequest) throws -> ServiceOperation {
        // Request IDs and deadlines change on retries; account, operation and payload do not.
        let canonical = ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID(""), accountID: account),
            operation: request.operation,
            payload: request.payload
        )
        let bytes = try ServiceCodec.encode(canonical)
        return try database.write { db in
            if let existing = try Data.fetchOne(
                db,
                sql: "SELECT request FROM serviceOperation WHERE id = ?",
                arguments: [id.rawValue]
            ) {
                guard existing == bytes,
                      let value = try Self.operation(id, db) else { throw ServiceFailure.operationConflict }
                return value
            }
            let value = ServiceOperation(id: id, state: "accepted")
            try db.execute(
                sql: "INSERT INTO serviceOperation (id, request, value) VALUES (?, ?, ?)",
                arguments: [id.rawValue, bytes, ServiceCodec.encode(value)]
            )
            return value
        }
    }

    public func finish(_ operation: ServiceOperation) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE serviceOperation SET value = ? WHERE id = ?",
                arguments: [ServiceCodec.encode(operation), operation.id.rawValue]
            )
            guard db.changesCount == 1 else { throw ServiceFailure.operationUnknown }
        }
    }

    private static func operation(_ id: ServiceOperationID, _ db: Database) throws -> ServiceOperation? {
        try Data.fetchOne(
            db,
            sql: "SELECT value FROM serviceOperation WHERE id = ?",
            arguments: [id.rawValue]
        )
        .map { try ServiceCodec.decode(ServiceOperation.self, from: $0) }
    }

    private static func sequence(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT sequence FROM serviceMetadata WHERE id = 1") ?? 0
    }

    private func checkpoint(_ db: Database) throws -> ServiceCursor {
        guard let stream = try String.fetchOne(db, sql: "SELECT stream FROM serviceMetadata WHERE id = 1")
        else {
            throw ServiceFailure.internalFailure
        }
        return try ServiceCursor(
            accountID: account,
            streamID: ServiceStreamID(stream),
            sequence: UInt64(Self.sequence(db))
        )
    }
}
