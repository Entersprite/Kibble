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

/// What a `MESSAGE_REACTED` body names: the message to refetch, and the topic
/// to refetch it from (`list_messages`' parent, `findings.md` §53.2).
struct ReactedMessage: Equatable {
    let messageID: ChatKit.Message.ID
    let parent: MessageParentId
}

extension ChannelEventMapping {
    /// The trigger for a reaction refetch, or `nil`.
    ///
    /// **Type 24 only, `[Verify]`.** No run has yet shown which event a
    /// reaction pushes (`findings.md` §53.3); 24 is the one every proto names.
    /// Dispatch is on the tag, never the body (§12.1.3). A body without a
    /// message id or a topic names nothing to refetch.
    static func reactedMessage(in body: ChannelEventBody) -> ReactedMessage? {
        guard body.typeTag == 24 else { return nil }
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        guard case let .messageReaction(event)? = decoded.message.type else { return nil }
        let identifier = event.messageID
        guard !identifier.messageID.isEmpty, !identifier.parentID.topicID.topicID.isEmpty,
              conversationID(identifier.parentID.topicID.groupID) != nil
        else { return nil }
        return ReactedMessage(
            messageID: ChatKit.Message.ID(identifier.messageID),
            parent: identifier.parentID
        )
    }
}
