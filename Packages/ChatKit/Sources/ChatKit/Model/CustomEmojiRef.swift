import Foundation

/// A workspace's custom emoji, by identity. No URL: the address Google hands
/// out for the image is ephemeral and not worth storing, so a backend fetches
/// the image by `id` (reactions spec §1.2, §2.4).
///
/// Coding is synthesised: two scalars, nothing to default.
public struct CustomEmojiRef: Codable, Hashable, Sendable {
    /// Google's uuid for the emoji. The identity: two workspaces can both
    /// have a `:parrot:`, and they are different emoji.
    public var id: String
    /// As Google sends it. Whether it arrives colon-wrapped is `[Verify]`
    /// until the probe run, which is why `displayText` wraps only once.
    public var shortcode: String

    public init(id: String, shortcode: String) {
        self.id = id
        self.shortcode = shortcode
    }

    /// `:shortcode:`, wrapped once whichever form Google sent.
    public var displayText: String {
        let bare = shortcode.hasPrefix(":") && shortcode.hasSuffix(":") && shortcode.count > 1
            ? String(shortcode.dropFirst().dropLast())
            : shortcode
        return ":\(bare):"
    }
}
