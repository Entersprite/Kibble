import ChatKit
import Foundation
import GChatBridgeCore

/// `Message.reactions` (field 21) becoming the domain's reaction set.
///
/// Shapes verified in `findings.md` §53.1 for unicode reactions: `Emoji`
/// field 1, a `count`, `current_user_participated` and `create_timestamp`.
/// The custom form (`Emoji` field 2, merged from purple's proto) is mapped the
/// same way and is `[Verify]` until a run sees one.
///
/// A reaction with no emoji, or a count below 1, is dropped: a capsule that
/// shows nothing, or zero, is noise, and the next refetch corrects any loss.
enum ReactionMapping {
    static func reactions(_ wire: [GChatBridgeCore.Reaction]) -> [ChatKit.Reaction] {
        wire.compactMap(reaction)
    }

    private static func reaction(_ wire: GChatBridgeCore.Reaction) -> ChatKit.Reaction? {
        let count = Int(wire.count)
        guard count >= 1 else { return nil }
        let emoji = wire.emoji
        if emoji.hasCustomEmoji {
            guard !emoji.customEmoji.uuid.isEmpty else { return nil }
            let ref = CustomEmojiRef(id: emoji.customEmoji.uuid, shortcode: emoji.customEmoji.shortcode)
            return ChatKit.Reaction(
                emoji: ref.displayText, count: count, includesMe: wire.currentUserParticipated,
                customEmoji: ref
            )
        }
        guard emoji.hasUnicode, !emoji.unicode.isEmpty else { return nil }
        return ChatKit.Reaction(emoji: emoji.unicode, count: count, includesMe: wire.currentUserParticipated)
    }
}
