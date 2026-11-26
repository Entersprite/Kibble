import ChatRules
import GRDB

extension Schema {
    static func addConversationActivity(_ db: Database) throws {
        try db.create(table: "activityTyping") {
            $0.column("conversationID", .text).notNull()
            $0.column("threadID", .text).notNull()
            $0.column("memberID", .text).notNull()
            $0.column("version", .integer)
            $0.column("isTyping", .boolean).notNull()
            $0.primaryKey(["conversationID", "threadID", "memberID"])
        }
        try db.create(table: "receiptAvailability") {
            $0.primaryKey("conversationID", .text)
            $0.column("enabled", .boolean).notNull()
        }
        try db.create(table: "readReceipt") {
            $0.column("conversationID", .text).notNull()
            $0.column("memberID", .text).notNull()
            $0.column("positionMicros", .integer).notNull()
            $0.primaryKey(["conversationID", "memberID"])
        }
    }
}
