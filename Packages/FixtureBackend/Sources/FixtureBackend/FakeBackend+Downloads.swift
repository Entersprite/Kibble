import ChatKit
import Foundation

public extension FakeBackend {
    /// `FixtureFile`'s bytes for any attachment some message in the world
    /// carries, in four fixed steps of progress. No clock and no wait: the
    /// steps are reported immediately, which is what keeps a test of this
    /// deterministic. Refuses an attachment the world does not hold, and an
    /// existing destination, rather than inventing or overwriting.
    func downloadAttachment(
        _ attachment: Attachment,
        to destination: URL,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        try require(capabilities.canDownloadFiles, "canDownloadFiles")
        guard world.messages.contains(where: { $0.attachments.contains { $0.id == attachment.id } }) else {
            throw ChatError.unknown("the fixture world holds no attachment \(attachment.id)")
        }
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw ChatError.unknown("the destination already exists")
        }
        let bytes = FixtureFile.bytes(for: attachment)
        for step in 1 ... 4 {
            progress(AttachmentProgress(bytesReceived: bytes.count * step / 4, totalBytes: bytes.count))
        }
        do {
            try bytes.write(to: destination, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ChatError.unknown("the fixture file could not be written")
        }
    }
}
