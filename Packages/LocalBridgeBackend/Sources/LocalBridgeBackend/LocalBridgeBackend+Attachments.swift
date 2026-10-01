import ChatKit
import Foundation
import GChatBridgeCore

/// An uploaded attachment's bytes - `attachmentData(_:size:)`.
///
/// `canFetchAttachments` is advertised because the path was measured end to
/// end on the live account (`findings.md` §51.2): `get_attachment_url`
/// answered one 302 to `lh3.googleusercontent.com`, which served the image to
/// a request carrying no credentials. `.original` is `[Verify]`: only the
/// preview size has been fetched live.
public extension LocalBridgeBackend {
    func attachmentData(_ attachment: ChatKit.Attachment, size: AttachmentSize) async throws -> Data {
        guard let attachmentFetch else {
            throw ChatError.unknown(
                "attachmentData(_:size:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        do {
            return try await attachmentFetch.fetch(
                token: attachment.id,
                contentType: attachment.contentType,
                variant: size == .preview ? .preview : .original
            ).body
        } catch {
            throw Self.chatError(fromAttachmentFetch: error.reason)
        }
    }

    /// What a view is told. Never the token, never a URL: the failure's hops
    /// carry hosts and statuses only, and none of them reach this either.
    internal static func chatError(fromAttachmentFetch reason: AttachmentFetchFailure.Reason) -> ChatError {
        switch reason {
        case .signInRedirect:
            .sessionExpired
        case let .httpStatus(status):
            .server(status: status, message: "the attachment fetch was refused")
        case .tooManyRedirects:
            .unknown("the attachment fetch redirected more than \(AttachmentFetch.maxHops) times")
        case .redirectWithoutLocation:
            .unknown("the attachment fetch was redirected nowhere")
        case .htmlInsteadOfAttachment:
            .unknown("the attachment fetch returned a page instead of the attachment")
        case let .transport(classified):
            .transport(classified?.safeDescription ?? "the attachment fetch failed")
        }
    }
}
