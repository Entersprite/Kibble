import ChatKit
import ChatRules
import Foundation
import GRDB

extension MessageRow {
    /// A read-only projection. Writes always target the underlying message table.
    static var currentHistory: QueryInterfaceRequest<MessageRow> {
        Table<MessageRow>("currentMessage").all()
    }
}

public extension ChatStore {
    func replicaHistoryEpoch() throws -> Int64 {
        try database.read(Self.fetchReplicaHistoryEpoch)
    }

    func observeReplicaHistoryEpoch() -> AsyncValueObservation<Int64> {
        ValueObservation.tracking(Self.fetchReplicaHistoryEpoch)
            .removeDuplicates().snapshotValues(in: database)
    }
}

extension ChatStore {
    static func fetchReplicaHistoryEpoch(_ db: Database) throws -> Int64 {
        guard let epoch = try Int64.fetchOne(db, sql: "SELECT epoch FROM replicaHistory WHERE id = 1"),
              epoch >= 0
        else { throw ChatError.decoding("History verification state is unavailable.") }
        return epoch
    }

    static func invalidateReplicaHistory(in db: Database) throws {
        let epoch = try fetchReplicaHistoryEpoch(db)
        guard epoch < Int64.max else { throw ChatError.decoding("History verification state is exhausted.") }
        try db.execute(sql: "UPDATE replicaHistory SET epoch = ? WHERE id = 1", arguments: [epoch + 1])
    }

    static func performHistoryConfidenceWrite(_ write: StoreWrite, in db: Database) throws {
        switch write {
        case .invalidateReplicaHistory: try invalidateReplicaHistory(in: db)
        case let .invalidateConversationHistory(ids): try invalidateConversationHistory(ids, in: db)
        default: break
        }
    }

    /// Withdraws confidence from these conversations' rows only. They are
    /// stamped below any epoch the account can hold (epochs start at 0), so
    /// `currentMessage` hides them until an authoritative page verifies each
    /// again. Every other conversation keeps its confidence; nothing is deleted.
    static func invalidateConversationHistory(_ ids: [Conversation.ID], in db: Database) throws {
        guard !ids.isEmpty else { return }
        let values = ids.map(\.rawValue)
        try db.execute(sql: """
        UPDATE message SET replicaHistoryEpoch = -1
        WHERE conversationID IN (\(databaseQuestionMarks(count: values.count))) AND replicaHistoryEpoch <> -1
        """, arguments: StatementArguments(values))
    }

    static func verifyMessageHistory(_ id: String, in db: Database) throws {
        try db.execute(sql: """
        UPDATE message SET replicaHistoryEpoch = (SELECT epoch FROM replicaHistory WHERE id = 1)
        WHERE id = ? AND replicaHistoryEpoch <> (SELECT epoch FROM replicaHistory WHERE id = 1)
        """, arguments: [id])
    }
}
