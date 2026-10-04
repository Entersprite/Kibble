import Foundation

/// Which emoji a reaction names - the only two shapes `Emoji` carries.
///
/// A oneof as a proper closed enum rather than two optional parameters: two
/// optionals can both be set or both be absent, and neither is a value this
/// type can even construct. `[Verify]` for a custom emoji whether the uuid
/// alone is accepted (reactions spec §2.3).
public enum ReactionEmoji: Sendable, Equatable {
    case unicode(String)
    case custom(id: String)
}

/// The shape that adds or removes one reaction.
///
/// A write, so no ladder - the reasoning `SendRequests` gives. Shape from
/// `mautrix_googlechat/maugclib/client.py:338-365`: the message named by its
/// full `MessageId` (group, topic, id), one `Emoji`, and ADD or REMOVE.
/// `[Verify]` until the owner's live check confirms it.
public enum ReactionRequests {
    public static func updateReaction(
        group: GroupId,
        topicID: String,
        messageID: String,
        emoji: ReactionEmoji,
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

        var builtEmoji = Emoji()
        switch emoji {
        case let .unicode(value):
            builtEmoji.unicode = value
        case let .custom(id):
            var custom = CustomEmoji()
            custom.uuid = id
            builtEmoji.customEmoji = custom
        }

        var request = UpdateReactionRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = identifier
        request.emoji = builtEmoji
        request.type = add ? .add : .remove
        return request
    }
}
