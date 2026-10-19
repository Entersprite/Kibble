import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend: BoundedMediaBackend {
    public func attachmentData(
        _ attachment: ChatKit.Attachment, size: AttachmentSize, maximumBytes: Int
    ) async throws -> Data {
        guard let attachmentFetch else { throw ChatError.notAuthenticated }
        do {
            return try await attachmentFetch.fetch(
                token: attachment.id, contentType: attachment.contentType,
                variant: size == .preview ? .preview : .original, maximumBytes: maximumBytes
            ).body
        } catch { throw Self.chatError(fromAttachmentFetch: error.reason) }
    }

    public func customEmojiImage(_ emoji: CustomEmojiRef, maximumBytes: Int) async throws -> Data {
        guard let token = emoji.imageToken, !token.isEmpty else {
            throw ChatError.unknown("this custom emoji has no image token")
        }
        guard let attachmentFetch else { throw ChatError.notAuthenticated }
        let fetched: FetchedAttachment
        do {
            fetched = try await attachmentFetch
                .customEmojiImage(readToken: token, maximumBytes: maximumBytes)
        } catch { throw Self.chatError(fromAttachmentFetch: error.reason) }
        guard fetched.contentType?.lowercased().hasPrefix("image/") == true else {
            throw ChatError.unknown("the custom emoji fetch returned something other than an image")
        }
        return fetched.body
    }

    public func remoteImage(_ url: URL, maximumBytes: Int) async throws -> Data {
        do {
            return try await RemoteImageFetch(transport: transport)
                .image(at: url, maximumBytes: maximumBytes)
        } catch { throw ChatError.unknown("a remote image could not be loaded (\(error))") }
    }

    public func downloadAttachment(
        _ attachment: ChatKit.Attachment, to destination: URL, maximumBytes: Int,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws {
        guard let attachmentFetch else { throw ChatError.notAuthenticated }
        guard await !credentials.hasUnscopedCookies else {
            throw ChatError.signInRequired("this session was stored before cookie domains were kept")
        }
        guard destination.isFileURL,
              !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw ChatError.unknown("the download's destination already exists or is unavailable")
        }
        do {
            _ = try await attachmentFetch.download(
                token: attachment.id, contentType: attachment.contentType,
                destination: destination, maximumBytes: maximumBytes
            ) { received, total in progress(AttachmentProgress(bytesReceived: received, totalBytes: total)) }
        } catch { throw Self.chatError(fromAttachmentFetch: error.reason) }
    }
}
