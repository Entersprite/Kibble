import Foundation

/// The shape that adds or removes one reaction.
///
/// A write, so no ladder - the reasoning `SendRequests` gives. Shape from
/// `mautrix_googlechat/maugclib/client.py:338-365`: the message named by its
/// full `MessageId` (group, topic, id), one `Emoji`, and ADD or REMOVE.
/// `[Verify]` until the owner's live check confirms it, and for a custom emoji
/// whether the uuid alone is accepted (reactions spec §2.3).
///
/// `unicode` and `customEmojiID` default to `nil` - not because either is
/// optional in practice (a real call always supplies exactly one), but
/// because six labelled parameters trips swiftlint's
/// `function_parameter_count`, and the two are a mutually exclusive pair
/// already expressed as two separate optionals rather than one. Every call
/// site still passes both explicitly.
public enum ReactionRequests {
    public static func updateReaction(
        group: GroupId,
        topicID: String,
        messageID: String,
        unicode: String? = nil,
        customEmojiID: String? = nil,
        add: Bool
    ) -> UpdateReactionRequest {
        var topic = TopicId()
        topic.groupID = group
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic
        var identifier = MessageId()
        identifier.parentID = parent
        identifier.messageID = messageID

        var emoji = Emoji()
        if let customEmojiID {
            var custom = CustomEmoji()
            custom.uuid = customEmojiID
            emoji.customEmoji = custom
        } else if let unicode {
            emoji.unicode = unicode
        }

        var request = UpdateReactionRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = identifier
        request.emoji = emoji
        request.type = add ? .add : .remove
        return request
    }
}
