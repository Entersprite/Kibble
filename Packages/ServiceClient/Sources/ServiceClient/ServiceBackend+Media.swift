import ChatAPI
import ChatKit
import Foundation

extension ServiceBackend: BoundedMediaBackend {
    public func attachmentData(_ attachment: Attachment, size: AttachmentSize) async throws -> Data {
        try await attachmentData(attachment, size: size, maximumBytes: 10 * 1024 * 1024)
    }

    public func attachmentData(
        _ attachment: Attachment,
        size: AttachmentSize,
        maximumBytes: Int
    ) async throws -> Data {
        guard capabilities.canFetchAttachments else { throw ServiceFailure.unsupportedOperation }
        return try await media(
            selector: .attachment(attachment.id),
            rendition: size.rawValue,
            maximumBytes: maximumBytes
        )
    }

    public func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data {
        try await customEmojiImage(emoji, maximumBytes: 10 * 1024 * 1024)
    }

    public func customEmojiImage(_ emoji: CustomEmojiRef, maximumBytes: Int) async throws -> Data {
        guard capabilities.canFetchCustomEmoji else { throw ServiceFailure.unsupportedOperation }
        return try await media(
            selector: .customEmoji(emoji.id),
            rendition: "image",
            maximumBytes: maximumBytes
        )
    }

    public func remoteImage(_ url: URL) async throws -> Data {
        try await remoteImage(url, maximumBytes: 10 * 1024 * 1024)
    }

    public func remoteImage(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard capabilities.canFetchRemoteImages else { throw ServiceFailure.unsupportedOperation }
        return try await media(selector: .remoteImage(url), rendition: "image", maximumBytes: maximumBytes)
    }

    public func downloadAttachment(
        _ attachment: Attachment, to destination: URL,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        try await downloadAttachment(
            attachment,
            to: destination,
            maximumBytes: 128 * 1024 * 1024,
            progress: progress
        )
    }

    public func downloadAttachment(
        _ attachment: Attachment, to destination: URL, maximumBytes: Int,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        guard capabilities.canDownloadFiles else { throw ServiceFailure.unsupportedOperation }
        guard destination.isFileURL else { throw ServiceFailure.invalidRequest }
        _ = try await media(
            selector: .attachment(attachment.id), rendition: "file", maximumBytes: maximumBytes,
            destination: destination, progress: progress
        )
    }
}

extension ServiceBackend {
    private func media(
        selector: MediaSelector, rendition: String, maximumBytes: Int, destination: URL? = nil,
        progress: @escaping @Sendable (AttachmentProgress) -> Void = { _ in }
    ) async throws -> Data {
        guard maximumBytes >= 0 else { throw ServiceFailure.invalidRequest }
        guard mediaTasks.count < 64 else { throw ServiceFailure.overloaded }
        let generation = connectionGeneration
        let id = UUID()
        let payload = BeginDownloadTransfer(
            operationID: .init(UUID().uuidString), selector: selector, rendition: rendition,
            maximumBytes: maximumBytes
        )
        let job = Task { try await withTransferPermit(.media) {
            try await self.downloadMedia(
                payload, destination: destination, generation: generation, progress: progress
            )
        } }
        mediaTasks[id] = job
        defer { mediaTasks[id] = nil }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }

    func checkMediaGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
    }
}
