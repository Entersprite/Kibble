import ChatKit
import Foundation

extension UploadTestBackend: BoundedMediaBackend {
    static let mediaBytes = Data((0 ..< 140_000).map { UInt8($0 % 251) })

    func holdMediaFetch(ignoreLimit: Bool = false) {
        holdMedia = true
        ignoreMediaLimit = ignoreLimit
    }

    func setMediaLength(_ count: Int) {
        mediaByteCount = count
    }

    func releaseMedia() {
        holdMedia = false; mediaWaiter?.resume(); mediaWaiter = nil
    }

    func attachmentData(
        _ attachment: Attachment,
        size: AttachmentSize,
        maximumBytes: Int
    ) async throws -> Data {
        mediaAttachments.append(attachment)
        return try await fetchMediaBytes(maximumBytes)
    }

    func customEmojiImage(_ emoji: CustomEmojiRef, maximumBytes: Int) async throws -> Data {
        mediaEmoji.append(emoji)
        return try await fetchMediaBytes(maximumBytes)
    }

    func remoteImage(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await fetchMediaBytes(maximumBytes)
    }

    func downloadAttachment(
        _ attachment: Attachment, to destination: URL, maximumBytes: Int,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        mediaAttachments.append(attachment)
        mediaFiles.append(destination)
        let bytes = try await fetchMediaBytes(maximumBytes)
        try bytes.write(to: destination, options: .withoutOverwriting)
        progress(.init(bytesReceived: bytes.count, totalBytes: bytes.count))
    }

    private func fetchMediaBytes(_ maximum: Int) async throws -> Data {
        if holdMedia {
            mediaHeld = true
            await withCheckedContinuation { mediaWaiter = $0 }
            mediaAcknowledged = true
        }
        // An already submitted provider request may finish after cancellation.
        let bytes = mediaByteCount.map { Self.mediaBytes.prefix($0) } ?? Self.mediaBytes
        guard bytes.count <= maximum || ignoreMediaLimit
        else { throw ChatError.unsupported(capability: "limit") }
        return bytes
    }
}
