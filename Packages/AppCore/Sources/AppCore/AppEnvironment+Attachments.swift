import ChatKit
import Foundation
import SyncEngine

/// The attachment cache's place in a session: built with the engine, offered
/// to the scene only when the backend can fetch, and erased on every path
/// into sign-in (`enterNeedsSignIn`).
extension AppEnvironment {
    /// The session's attachments are not looked up yet: there is no session.
    struct NoSession: Error {}

    func makeAttachmentCache(in directory: URL?, engine: SyncEngine) -> AttachmentCache {
        AttachmentCache(directory: directory) { [engine] attachment, size in
            try await engine.attachmentData(attachment, size: size)
        }
    }

    var canFetchAttachments: Bool {
        runningModel?.capabilities.canFetchAttachments == true
    }

    /// Read through `self` at call time, never captured: a view still on
    /// screen during sign-out holds the closure it was given, and must reach
    /// no cache once this one is gone.
    func loadAttachment(_ attachment: Attachment, size: AttachmentSize) async throws -> Data {
        guard let attachments else { throw NoSession() }
        return try await attachments.data(for: attachment, size: size)
    }

    func openAttachment(_ attachment: Attachment) async throws -> URL {
        guard let attachments else { throw NoSession() }
        return try await attachments.originalFile(for: attachment)
    }

    /// Cleared before it is erased, so nothing can start a fetch on it
    /// mid-erase; a fetch already running is disowned by `erase()` itself.
    func eraseAttachments() async {
        let cache = attachments
        attachments = nil
        await cache?.erase()
    }
}
