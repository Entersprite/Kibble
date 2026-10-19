import ChatKit
import Foundation

extension FakeBackend: BoundedMediaBackend {
    public func attachmentData(
        _ attachment: Attachment,
        size: AttachmentSize,
        maximumBytes: Int
    ) async throws -> Data {
        try await limited(attachmentData(attachment, size: size), maximumBytes: maximumBytes)
    }

    public func customEmojiImage(_ emoji: CustomEmojiRef, maximumBytes: Int) async throws -> Data {
        try await limited(customEmojiImage(emoji), maximumBytes: maximumBytes)
    }

    public func remoteImage(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await limited(remoteImage(url), maximumBytes: maximumBytes)
    }

    public func downloadAttachment(
        _ attachment: Attachment, to destination: URL, maximumBytes: Int,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        try require(capabilities.canDownloadFiles, "canDownloadFiles")
        guard world.messages.contains(where: { $0.attachments.contains { $0.id == attachment.id } }) else {
            throw ChatError.unknown("the fixture world holds no such attachment")
        }
        let bytes = try limited(FixtureFile.bytes(for: attachment), maximumBytes: maximumBytes)
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw ChatError.unknown("the destination already exists or is unavailable")
        }
        try Task.checkCancellation()
        try Data().write(to: destination, options: .withoutOverwriting)
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.write(contentsOf: bytes)
            progress(AttachmentProgress(bytesReceived: bytes.count, totalBytes: bytes.count))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func limited(_ bytes: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, bytes.count <= maximumBytes else {
            throw ChatError.unknown("the media exceeds the permitted byte limit")
        }
        return bytes
    }
}
