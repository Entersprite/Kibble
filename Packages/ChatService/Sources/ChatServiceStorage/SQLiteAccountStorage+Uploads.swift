import ChatAPI
import ChatKit
import ChatService
import Foundation
import GRDB

extension SQLiteAccountStorage: ServiceUploadReferences {
    public func rememberUpload(
        _ attachment: Attachment, in conversation: Conversation.ID, at date: Date, until expiry: Date
    ) throws {
        let value = try ServiceCodec.encode(attachment)
        guard value.count <= ServiceBinaryLimits.maximumHeaderBytes
        else { throw ServiceFailure.frameTooLarge }
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM serviceUploadReference WHERE expiresAt <= ?",
                arguments: [date.timeIntervalSince1970]
            )
            let exists = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM serviceUploadReference WHERE id = ? AND conversationID = ?)
            """, arguments: [attachment.id, conversation.rawValue]) == true
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM serviceUploadReference") ?? 0
            guard exists || count < 4096 else { throw ServiceFailure.overloaded }
            try db.execute(sql: """
            INSERT INTO serviceUploadReference (id, conversationID, value, expiresAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(id, conversationID) DO UPDATE
                SET value = excluded.value, expiresAt = excluded.expiresAt
            """, arguments: [attachment.id, conversation.rawValue, value, expiry.timeIntervalSince1970])
        }
    }

    public func uploadedAttachment(
        _ id: String, in conversation: Conversation.ID, at date: Date
    ) throws -> Attachment? {
        try database.read { db in
            try Data.fetchOne(db, sql: """
            SELECT value FROM serviceUploadReference WHERE id = ? AND conversationID = ? AND expiresAt > ?
            """, arguments: [id, conversation.rawValue, date.timeIntervalSince1970])
                .map { try ServiceCodec.decode(Attachment.self, from: $0) }
        }
    }
}
