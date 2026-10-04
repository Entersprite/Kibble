import Foundation

/// The one value a person picks: a unicode emoji, or a custom one. In ChatKit
/// rather than DesignSystem because SyncEngine's recents return it, and
/// SyncEngine depends on ChatKit alone (reactions spec §1.2).
public struct ReactionChoice: Hashable, Sendable {
    /// The emoji itself, or a custom emoji's `displayText`.
    public var emoji: String
    public var customEmoji: CustomEmojiRef?

    public init(emoji: String) {
        self.emoji = emoji
        customEmoji = nil
    }

    public init(customEmoji: CustomEmojiRef) {
        emoji = customEmoji.displayText
        self.customEmoji = customEmoji
    }

    /// What a reaction is matched on. Prefixed for a custom emoji so an id can
    /// never collide with a unicode string.
    public var key: String {
        customEmoji.map { "custom/\($0.id)" } ?? emoji
    }
}
