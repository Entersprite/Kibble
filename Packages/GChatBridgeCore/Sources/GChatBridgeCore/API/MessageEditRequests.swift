import Foundation

/// The shapes that edit and delete one of the person's own messages.
///
/// Writes, so no ladder: the reasoning `SendRequests` gives. Shapes from
/// `maugclib/client.py:367-410`: the message named by its full `MessageId`
/// (group, topic, id), as `ReactionRequests` names one. An edit sends the new
/// text, its annotations and `accept_format_annotations`, as the reference
/// does. `[Verify]` until `--probe=edit` runs (edit spec §1).
public enum MessageEditRequests {
    public static func editMessage(
        group: GroupId,
        topicID: String,
        messageID: String,
        text: String,
        annotations: [Annotation]
    ) -> EditMessageRequest {
        var info = MessageInfo()
        info.acceptFormatAnnotations = true
        var request = EditMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = identifier(group: group, topicID: topicID, messageID: messageID)
        request.textBody = text
        request.annotations = annotations
        request.messageInfo = info
        return request
    }

    public static func deleteMessage(
        group: GroupId,
        topicID: String,
        messageID: String
    ) -> DeleteMessageRequest {
        var request = DeleteMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.messageID = identifier(group: group, topicID: topicID, messageID: messageID)
        return request
    }

    private static func identifier(group: GroupId, topicID: String, messageID: String) -> MessageId {
        var topic = TopicId()
        topic.groupID = group
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic
        var identifier = MessageId()
        identifier.parentID = parent
        identifier.messageID = messageID
        return identifier
    }
}
