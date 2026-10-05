import ChatKit
import Foundation
import GChatBridgeCore

/// A custom emoji's picture - `customEmojiImage(_:)`.
///
/// `canFetchCustomEmoji` is advertised on `findings.md` §54.4's capture of
/// Chat on the web, plus §51's twin call, which worked through the same walk
/// on its first run. The live fetch from this client is `[Verify]`.
///
/// The final hop's `Content-Type` must start `image/`, checked here rather
/// than left to the caller: `AttachmentCache` writes whatever this returns to
/// disk, keyed by the emoji's id, and keeps it there across relaunches, so a
/// 200 that is not a picture would be cached as the emoji for good.
public extension LocalBridgeBackend {
    func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data {
        // Before the session check, so a reference with no token never
        // depends on whether the session is up: it cannot be fetched either way.
        guard let readToken = emoji.imageToken, !readToken.isEmpty else {
            throw ChatError.unknown("this custom emoji has no image token")
        }
        guard let attachmentFetch else {
            throw ChatError.unknown(
                "customEmojiImage(_:) requires connect() to succeed first - there is no verified session yet"
            )
        }
        let fetched: FetchedAttachment
        do {
            fetched = try await attachmentFetch.customEmojiImage(readToken: readToken)
        } catch {
            throw Self.chatError(fromAttachmentFetch: error.reason)
        }
        guard fetched.contentType?.lowercased().hasPrefix("image/") == true else {
            throw ChatError.unknown("the custom emoji fetch returned something other than an image")
        }
        return fetched.body
    }
}
