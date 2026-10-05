import ChatKit
import Foundation

public extension SyncEngine {
    /// An attachment's bytes, from the backend. Forwarded, because nothing
    /// above this actor talks to a backend directly.
    ///
    /// **Thrown, never recorded.** A failed image is the view's to show where
    /// the image would have been; a banner for every picture that could not
    /// load, in a conversation with forty of them, would be noise. This is the
    /// same posture `watchPresence(in:)` takes for a hint.
    func attachmentData(_ attachment: Attachment, size: AttachmentSize) async throws -> Data {
        try await backend.attachmentData(attachment, size: size)
    }

    /// The backend's download, unchanged: a file is the caller's, not the
    /// store's, so nothing here is cached or recorded.
    func downloadAttachment(
        _ attachment: Attachment,
        to destination: URL,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        try await backend.downloadAttachment(attachment, to: destination, progress: progress)
    }

    /// The backend's upload, with a failure **recorded** as well as thrown,
    /// unlike a picture's: a file that will not upload is a send that did not
    /// happen, and says so the way a refused send does (`submit`). Not
    /// recorded once cancelled, for `submit`'s reason.
    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> Attachment {
        do {
            return try await backend.uploadAttachment(attachment, to: conversation, progress: progress)
        } catch {
            if !Task.isCancelled {
                record(error)
            }
            throw error
        }
    }

    /// A custom emoji's picture, from the backend. Thrown, never recorded,
    /// for `attachmentData(_:size:)`'s reason: a capsule that cannot load
    /// shows its shortcode, which is the whole of the failure.
    func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data {
        try await backend.customEmojiImage(emoji)
    }
}
