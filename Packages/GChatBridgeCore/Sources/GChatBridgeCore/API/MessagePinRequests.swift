import Foundation

/// The Board uses shared message label2, independent of resource pins.
public enum MessagePinRequests {
    public static func list(in group: GroupId) -> ListMessagesRequest {
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID.groupID = group
        request.parentID.topicID.topicID = ""
        request.pageSize = 100
        var label = MessageLabel(); label.labelType = 2
        request.filter.labels = [label]
        request.filter.labelTimeAnchor = -1
        return request
    }

    public static func address(group: GroupId, topic: String, message: String) -> MessageId {
        var id = MessageId()
        id.parentID.topicID.groupID = group
        id.parentID.topicID.topicID = topic
        id.messageID = message
        return id
    }

    public static func message(_ id: MessageId) -> GetMessageRequest {
        var request = GetMessageRequest()
        request.requestHeader = APIRequestHeader.make(); request.messageID = id
        return request
    }

    public static func apply(_ id: MessageId) -> ApplyMessageLabelRequest {
        var request = ApplyMessageLabelRequest()
        request.requestHeader = APIRequestHeader.make(); request.messageID = id
        request.label.labelType = 2; request.label.createTime = 0
        return request
    }

    public static func remove(_ id: MessageId) -> RemoveMessageLabelRequest {
        var request = RemoveMessageLabelRequest()
        request.requestHeader = APIRequestHeader.make(); request.messageID = id
        request.label.labelType = 2; request.label.createTime = 0
        return request
    }
}

public extension APIMethod where Request == GetMessageRequest, Response == GetMessageResponse {
    static var pinTarget: Self {
        Self("get_message")
    }
}

public extension APIMethod where Request == ApplyMessageLabelRequest, Response == ApplyMessageLabelResponse {
    static var applyPin: Self {
        Self("apply_message_label", allowsEmptyResponse: true)
    }
}

public extension APIMethod where Request == RemoveMessageLabelRequest,
    Response == RemoveMessageLabelResponse {
    static var removePin: Self {
        Self("remove_message_label", allowsEmptyResponse: true)
    }
}
