import ChatKit
import Foundation

public extension FakeBackend {
    /// An attachment named for the staged file, with a fixture token, in four
    /// fixed steps of progress. The file is never read: no clock, no wait and
    /// no disk, which is what keeps a test of this deterministic. Refuses a
    /// conversation the world does not hold rather than inventing one.
    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        try requireConnected()
        try require(capabilities.canSendAttachments, "canSendAttachments")
        guard world.conversation(conversation) != nil else {
            throw ChatError.unknown("no conversation \(conversation) in this fixture world")
        }
        for step in 1 ... 4 {
            progress(AttachmentProgress(
                bytesReceived: attachment.byteSize * step / 4, totalBytes: attachment.byteSize
            ))
        }
        let uploaded = Attachment(
            id: nextIdentifier("fixture-upload"),
            name: attachment.name,
            contentType: attachment.contentType,
            byteSize: attachment.byteSize,
            width: attachment.width,
            height: attachment.height
        )
        self.uploaded[uploaded.id] = uploaded
        return uploaded
    }
}
