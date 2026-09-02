import Foundation

/// The two shapes that post a message.
///
/// ## Why there is no ladder here
///
/// `WorldRequestLadder` and `TopicsRequestLadder` each send four candidate
/// shapes and let the comparison be the finding, because a read costs nothing
/// but latency and §20.1 proved the references disagree about what actually
/// works. **A send is a write.** Four rungs would post four messages into
/// somebody's real conversation, and no protocol answer is worth that. So this
/// is one shape, copied from the one worked example, and marked `[Verify]`
/// until a single deliberate send confirms it.
///
/// ## Where the shape comes from
///
/// `mautrix_googlechat/maugclib/client.py:442-472`. Two paths, chosen by
/// whether there is a thread to reply into - `client.py:441`'s `if thread_id:`:
///
/// - **no thread → `create_topic`**, carrying `group_id` and `history_v2: true`
/// - **thread → `create_message`**, carrying `parent_id` and no `history_v2`
///   (the field does not exist on that request)
///
/// Both carry `local_id`, which the server echoes back on the resulting
/// `Message` - that is what `ChatKit.Message.localID` exists for, and what lets
/// a client replace an optimistic copy instead of showing the message twice.
///
/// `annotations` is left empty on both. The reference passes formatting
/// annotations through from Matrix; there is no formatting in this client's
/// composer yet, and sending an empty repeated field is identical on the wire
/// to not sending one.
public enum SendRequests {
    /// A new top-level message. The only path a flat conversation has, and
    /// `findings.md` §20.4 observed every conversation on the test account is
    /// flat.
    public static func createTopic(
        group: GroupId,
        text: String,
        localID: String
    ) -> CreateTopicRequest {
        var request = CreateTopicRequest()
        request.requestHeader = APIRequestHeader.make()
        request.groupID = group
        request.localID = localID
        request.textBody = text
        // `client.py:465`. Set on this path and absent from the other, because
        // `CreateMessageRequest` has no such field.
        request.historyV2 = true
        request.messageInfo = messageInfo()
        return request
    }

    /// A reply inside an existing thread. **Unexercised against live traffic
    /// and untestable on the current account** - §20.4 found `threaded_group`
    /// on none of its conversations - so this is the reference's shape and
    /// nothing more.
    public static func createMessage(
        group: GroupId,
        topicID: String,
        text: String,
        localID: String
    ) -> CreateMessageRequest {
        var topic = TopicId()
        topic.groupID = group
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic

        var request = CreateMessageRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID = parent
        request.localID = localID
        request.textBody = text
        request.messageInfo = messageInfo()
        return request
    }

    /// `client.py:454` / `:468`, both paths identically.
    ///
    /// `reply_to` is deliberately not assigned. The reference passes `None`
    /// when there is no reply target, and in protobuf an unassigned message
    /// field is absent - assigning a default-constructed `SendReplyTarget`
    /// would put bytes on the wire the reference never sends.
    private static func messageInfo() -> MessageInfo {
        var info = MessageInfo()
        info.acceptFormatAnnotations = true
        return info
    }

    /// The client-chosen id for one send.
    ///
    /// Shaped like the reference's `f"hangups%{random.randint(...)}"`
    /// (`client.py:440`) with this client's own prefix, so a support question
    /// about a stuck message can tell which client produced it.
    public static func makeLocalID() -> String {
        "gchat%\(UInt64.random(in: 0 ... UInt64.max))"
    }
}
