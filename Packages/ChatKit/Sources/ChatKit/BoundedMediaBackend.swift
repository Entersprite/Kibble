import Foundation

/// Optional provider port for a service that reserves media resources before I/O.
/// Implementations enforce the actual response ceiling while reading, including
/// redirects. Destinations are owned by the caller and must not already exist.
/// These local SDK methods are not a network DTO or client-file transport.
public protocol BoundedMediaBackend: ChatBackend {
    func attachmentData(_ attachment: Attachment, size: AttachmentSize, maximumBytes: Int) async throws
        -> Data
    func customEmojiImage(_ emoji: CustomEmojiRef, maximumBytes: Int) async throws -> Data
    func remoteImage(_ url: URL, maximumBytes: Int) async throws -> Data
    func downloadAttachment(
        _ attachment: Attachment, to destination: URL, maximumBytes: Int,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws
}
