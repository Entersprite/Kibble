import GRDB

extension Schema {
    static func addReplicaHistory(_ db: Database) throws {
        try db.alter(table: "message") { table in
            table.add(column: "replicaHistoryEpoch", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "replicaHistory") { table in
            table.primaryKey("id", .integer)
            table.column("epoch", .integer).notNull()
        }
        try db.execute(sql: "INSERT INTO replicaHistory (id, epoch) VALUES (1, 0)")
        try db.create(
            index: "message_conversation_epoch_created",
            on: "message",
            columns: ["conversationID", "replicaHistoryEpoch", "createdAt", "id"]
        )
        try db.execute(sql: """
        CREATE VIEW currentMessage AS
        SELECT message.* FROM message
        WHERE replicaHistoryEpoch = (SELECT epoch FROM replicaHistory WHERE id = 1)
        UNION ALL
        SELECT message.* FROM messageDelivery
        JOIN message ON message.id = messageDelivery.messageID
        WHERE message.replicaHistoryEpoch <> (SELECT epoch FROM replicaHistory WHERE id = 1)
        """)
    }
}
