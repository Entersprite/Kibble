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
}
