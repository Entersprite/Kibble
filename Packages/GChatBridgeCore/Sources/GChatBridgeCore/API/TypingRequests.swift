import Foundation

public extension APIMethod where Request == SetTypingStateRequest, Response == SetTypingStateResponse {
    static var setTypingState: Self {
        Self("set_typing_state")
    }
}

/// The provider's group/topic context, using the same header as its other API calls.
public enum TypingRequests {
    public static func make(group: GroupId, topic: String?, typing: Bool) -> SetTypingStateRequest {
        var request = SetTypingStateRequest()
        request.requestHeader = APIRequestHeader.make()
        request.state = typing ? .typing : .stopped
        if let topic {
            request.context.topicID.groupID = group
            request.context.topicID.topicID = topic
        } else {
            request.context.groupID = group
        }
        return request
    }
}
