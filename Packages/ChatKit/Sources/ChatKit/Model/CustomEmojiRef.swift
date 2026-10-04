import Foundation

/// A workspace's custom emoji, by identity, with the backend's handle for its
/// picture. No URL: the address Google hands out in a push is ephemeral and
/// absent from history (`findings.md` §54.3), so a backend fetches the image
/// with `imageToken` instead (reactions spec §2.4).
///
/// Coding is synthesised. `imageToken` is optional, so it is written only
/// when present and a stored reference without one decodes as `nil`, which
/// keeps `reaction-custom.json` byte-identical.
public struct CustomEmojiRef: Codable, Hashable, Sendable {
    /// Google's uuid for the emoji. The identity: two workspaces can both
    /// have a `:parrot:`, and they are different emoji.
    public var id: String
    /// As Google sends it. Whether it arrives colon-wrapped is `[Verify]`,
    /// which is why `displayText` wraps only once.
    public var shortcode: String
    /// The backend's own opaque handle for the picture, handed back to
    /// `ChatBackend.customEmojiImage(_:)`, the way `Attachment.id` is for an
    /// upload. For the local bridge it is Google's `read_token`
    /// (`findings.md` §54.4). `nil` for a reference stored before it was
    /// kept, or built without one: the capsule shows the shortcode until the
    /// next history load supplies it.
    ///
    /// Not part of the identity: `ReactionChoice.key` is the `id` alone.
    /// Equality still compares it, as a value.
    public var imageToken: String?

    public init(id: String, shortcode: String, imageToken: String? = nil) {
        self.id = id
        self.shortcode = shortcode
        self.imageToken = imageToken
    }

    /// `:shortcode:`, wrapped once whichever form Google sent.
    public var displayText: String {
        let bare = shortcode.hasPrefix(":") && shortcode.hasSuffix(":") && shortcode.count > 1
            ? String(shortcode.dropFirst().dropLast())
            : shortcode
        return ":\(bare):"
    }
}
