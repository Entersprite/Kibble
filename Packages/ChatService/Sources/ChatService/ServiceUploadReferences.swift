import ChatKit
import Foundation

/// Only a completed service-owned upload can authorize a file on a later send.
public protocol ServiceUploadReferences: Sendable {
    func rememberUpload(
        _ attachment: Attachment,
        in conversation: Conversation.ID,
        at: Date,
        until: Date
    ) throws
    func uploadedAttachment(_ id: String, in conversation: Conversation.ID, at: Date) throws -> Attachment?
}
