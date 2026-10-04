import ChatKit
import Foundation
import GChatBridgeCore

/// A custom emoji's picture - `customEmojiImage(_:)`.
///
/// `canFetchCustomEmoji` is advertised on `findings.md` §54.4's capture of
/// Chat on the web, plus §51's twin call, which worked through the same walk
/// on its first run. The live fetch from this client is `[Verify]`.
public extension LocalBridgeBackend {
    func customEmojiImage(_ emoji: CustomEmojiRef) async throws -> Data {
        // Before the session check, so a reference with no token never
        // depends on whether the session is up: it cannot be fetched either way.
        guard let readToken = emoji.imageToken, !readToken.isEmpty else {
            throw ChatError.unknown(
                "this custom emoji has no image token yet; the next history load supplies one"
            )
        }
        guard let attachmentFetch else {
            throw ChatError.unknown(
                "customEmojiImage(_:) requires connect() to succeed first - there is no verified session yet"
            )
        }
        do {
            return try await attachmentFetch.customEmojiImage(readToken: readToken).body
        } catch {
            throw Self.chatError(fromAttachmentFetch: error.reason)
        }
    }
}
