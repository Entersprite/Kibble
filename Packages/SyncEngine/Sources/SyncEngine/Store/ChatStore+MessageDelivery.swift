import ChatKit
import ChatRules
import Foundation
import GRDB

public struct PendingMessageDelivery: Sendable, Equatable {
    public let messageID: Message.ID
    public let localID: String
    public let status: MessageDeliveryStatus
}

public extension ChatStore {
    func messageDeliveries() throws -> [PendingMessageDelivery] {
        try database.read(Self.fetchMessageDeliveries)
    }

    func observeMessageDeliveries() -> AsyncValueObservation<[PendingMessageDelivery]> {
        ValueObservation.tracking(Self.fetchMessageDeliveries).removeDuplicates().snapshotValues(in: database)
    }
}

extension ChatStore {
    static func performDeliveryWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case let .beginMessageDelivery(id):
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messageDelivery WHERE messageID = ?)",
                arguments: [id.rawValue]
            ) ?? false
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageDelivery") ?? 0
            guard exists || count < 512 else {
                throw ChatError.unknown("Check pending message deliveries before sending more.")
            }
            try db.execute(sql: """
            INSERT INTO messageDelivery (messageID, localID, state)
            SELECT id, localID, ? FROM message WHERE id = ? AND localID IS NOT NULL
            ON CONFLICT(messageID) DO UPDATE SET state = excluded.state
            """, arguments: [MessageDeliveryStatus.sending.rawValue, id.rawValue])
        case let .setMessageDelivery(id, status):
            // Never recreate a pending row after the canonical echo removed
            // its optimistic message, or after account/history erasure.
            try db.execute(
                sql: """
                UPDATE messageDelivery SET state = ? WHERE messageID = ? AND state <> ?
                    AND state NOT IN ('sent', 'failed')
                """,
                arguments: [status.rawValue, id.rawValue, status.rawValue]
            )
        case .interruptMessageDeliveries:
            try db.execute(
                sql: "UPDATE messageDelivery SET state = ? WHERE state = ?",
                arguments: [
                    MessageDeliveryStatus.unconfirmed.rawValue,
                    MessageDeliveryStatus.sending.rawValue
                ]
            )
        default: break
        }
    }

    static func fetchMessageDeliveries(_ db: Database) throws -> [PendingMessageDelivery] {
        try Row.fetchAll(db, sql: """
        SELECT messageID, state, localID FROM messageDelivery ORDER BY messageID
        """).map {
            PendingMessageDelivery(
                messageID: Message.ID($0["messageID"]),
                localID: $0["localID"],
                status: MessageDeliveryStatus(rawValue: $0["state"])
            )
        }
    }
}
