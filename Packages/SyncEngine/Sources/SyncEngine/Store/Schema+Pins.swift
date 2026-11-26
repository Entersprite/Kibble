import GRDB

extension Schema {
    static func cacheMessagePins(_ db: Database) throws {
        try db.create(table: "messagePins") { table in
            table.primaryKey("conversationID", .text)
                .references("conversation", onDelete: .cascade)
            table.column("value", .text).notNull()
        }
    }

    static func addMessagePins(_ db: Database) throws {
        try db.create(table: "messagePinRevision") { table in
            table.primaryKey("conversationID", .text)
                .references("conversation", onDelete: .cascade)
            table.column("revision", .integer).notNull()
        }
        try db.alter(table: "message") { $0.add(column: "activity", .text) }
    }
}
