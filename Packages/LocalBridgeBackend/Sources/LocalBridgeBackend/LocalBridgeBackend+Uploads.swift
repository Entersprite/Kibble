import ChatKit
import Foundation
import GChatBridgeCore

/// Uploading a file - `uploadAttachment(_:to:progress:)` - and the annotations
/// a send then carries for it.
///
/// `canSendAttachments` is advertised on the two references' agreement
/// (purple `googlechat_conversation.c:1780-1890`, maugclib `client.py:275-320`)
/// and is `[Verify]` until `--probe=upload` and a first send run live.
public extension LocalBridgeBackend {
    func uploadAttachment(
        _ attachment: OutgoingAttachment,
        to conversation: Conversation.ID,
        progress: @escaping @Sendable (AttachmentProgress) -> Void
    ) async throws -> ChatKit.Attachment {
        guard let attachmentUpload else {
            throw ChatError.unknown(
                "uploadAttachment(_:to:progress:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let group = ChannelEventMapping.groupID(for: conversation) else {
            throw ChatError.unknown(
                "\(conversation.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces, so nothing can be uploaded into it"
            )
        }
        let metadata: UploadMetadata
        do {
            metadata = try await attachmentUpload.upload(
                UploadFile(
                    url: attachment.file,
                    name: attachment.name,
                    contentType: attachment.contentType,
                    byteCount: attachment.byteSize
                ),
                group: group
            ) { sent, total in
                progress(AttachmentProgress(bytesReceived: sent, totalBytes: total))
            }
        } catch {
            throw Self.chatError(fromUpload: error.reason)
        }
        uploadedMetadata[metadata.attachmentToken] = metadata
        return Self.attachment(from: metadata, staged: attachment)
    }

    /// The attachment a message will show: the server's own name and type
    /// when it said, the staged file's otherwise, and the staged size, which
    /// the metadata does not carry. `id` is the token, the same handle a
    /// received upload has (`ChannelEventMapping.attachments(_:)`).
    internal static func attachment(
        from metadata: UploadMetadata,
        staged: OutgoingAttachment
    ) -> ChatKit.Attachment {
        let dimension = metadata.hasOriginalDimension ? metadata.originalDimension : nil
        let measured = dimension.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        return ChatKit.Attachment(
            id: metadata.attachmentToken,
            name: metadata.contentName.isEmpty ? staged.name : metadata.contentName,
            contentType: metadata.contentType.isEmpty ? staged.contentType : metadata.contentType,
            byteSize: staged.byteSize,
            width: measured.map { Int($0.width) } ?? staged.width,
            height: measured.map { Int($0.height) } ?? staged.height
        )
    }

    /// One type-13 annotation per attachment. The metadata this session's
    /// upload returned is sent back verbatim, as purple sends it, because the
    /// upload answers with fields no proto names (`findings.md` §51.1 counts
    /// eleven on a received one). An attachment this session did not upload is
    /// rebuilt from what the domain kept: the token, name, type and size.
    internal static func uploadAnnotations(
        _ attachments: [ChatKit.Attachment],
        uploaded: [String: UploadMetadata]
    ) -> [GChatBridgeCore.Annotation] {
        attachments.map { attachment in
            SendRequests.uploadAnnotation(uploaded[attachment.id] ?? rebuiltMetadata(attachment))
        }
    }

    private static func rebuiltMetadata(_ attachment: ChatKit.Attachment) -> UploadMetadata {
        var metadata = UploadMetadata()
        metadata.attachmentToken = attachment.id
        metadata.contentName = attachment.name
        metadata.contentType = attachment.contentType
        if let width = attachment.width, let height = attachment.height {
            var dimension = Dimension()
            dimension.width = Int32(clamping: width)
            dimension.height = Int32(clamping: height)
            metadata.originalDimension = dimension
        }
        return metadata
    }

    /// What a view is told. Never the address, never the token.
    internal static func chatError(fromUpload reason: AttachmentUploadFailure.Reason) -> ChatError {
        switch reason {
        case .signInRedirect:
            .sessionExpired
        case let .startRefused(status):
            .server(status: status, message: "the upload was refused before it started")
        case let .uploadRefused(status):
            .server(status: status, message: "the upload's bytes were refused")
        case .noUploadURL:
            .unknown("the upload did not start: Google returned no upload address")
        case .uploadURLRefused:
            .unknown("the upload address was not on Google's chat host, so nothing was sent to it")
        case .undecodableMetadata:
            .decoding("the upload finished, but its answer could not be read")
        case .noAttachmentToken:
            .decoding("the upload finished, but its answer named no attachment")
        case let .transport(classified):
            .transport(classified?.safeDescription ?? "the upload failed")
        }
    }
}
