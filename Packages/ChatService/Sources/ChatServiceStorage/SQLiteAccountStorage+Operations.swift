import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

public extension SQLiteAccountStorage {
    func operation(_ id: ServiceOperationID) throws -> ServiceOperation? {
        try database.read { db in try Self.operation(id, db) }
    }

    func reserve(_ id: ServiceOperationID, request: ServiceRequest) throws -> ServiceOperation {
        // Request IDs and deadlines change on retries; account, operation and payload do not.
        let canonical = ServiceRequest(
            header: ServiceRequestHeader(requestID: ServiceRequestID(""), accountID: account),
            operation: request.operation,
            payload: request.payload
        )
        let bytes = try ServiceCodec.encode(canonical)
        return try database.write { db in
            try pruneRetention(db)
            if let existing = try Data.fetchOne(
                db,
                sql: "SELECT request FROM serviceOperation WHERE id = ?",
                arguments: [id.rawValue]
            ) {
                guard existing == bytes,
                      let value = try Self.operation(id, db) else { throw ServiceFailure.operationConflict }
                return value
            }
            let expiry = try operationExpiry(id, db: db)
            let value = ServiceOperation(id: id, state: "accepted")
            try checkOperationCapacity(
                db, bytes: bytes.count + ServiceCodec.encode(value).count, legacy: expiry == nil
            )
            try db.execute(
                sql: "INSERT INTO serviceOperation (id, request, value, expiresAt) VALUES (?, ?, ?, ?)",
                arguments: [id.rawValue, bytes, ServiceCodec.encode(value), expiry]
            )
            return value
        }
    }

    func finish(_ operation: ServiceOperation) throws {
        let overflow = try database.write { db in
            var bytes = try ServiceCodec.encode(operation)
            let stored = try Int.fetchOne(
                db,
                sql: "SELECT SUM(length(request) + length(value)) FROM serviceOperation"
            ) ?? 0
            let old = try Int.fetchOne(
                db,
                sql: "SELECT length(value) FROM serviceOperation WHERE id = ?",
                arguments: [operation.id.rawValue]
            ) ?? 0
            let overflow = bytes.count > limits.operationBytes - stored + old
            if overflow {
                // Keep the dispatch uncertainty even when a large result cannot fit.
                bytes = try ServiceCodec.encode(ServiceOperation(id: operation.id, state: "unknown"))
            }
            try db.execute(
                sql: "UPDATE serviceOperation SET value = ? WHERE id = ?",
                arguments: [bytes, operation.id.rawValue]
            )
            guard db.changesCount == 1 else { throw ServiceFailure.operationUnknown }
            return overflow
        }
        if overflow {
            throw ServiceFailure.operationUnknown
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
}
