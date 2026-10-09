import ChatKit
import Foundation
import GChatBridgeCore

/// The thread pushes (threads spec §2.3), matched by type tag: 53 and 82
/// have no name in the vendored `EventType`, and a body field number is not
/// a type number (`findings.md` §12.1.3). `nil` means the body is routed as
/// unknown, like any other body this bridge cannot read.
extension ChannelEventMapping {
    static func threadEvent(in body: ChannelEventBody) -> ChatEvent? {
        switch body.typeTag {
        case 4: topicViewed(in: body)
        case 9: topicMuteChanged(in: body)
        case 53: unreadThreads(in: body)
        case 82: topicMetadata(in: body)
        default: nil
        }
    }

    private static func decoded(_ body: ChannelEventBody) -> Event.EventBody.OneOf_Type? {
        PBLiteDecoder.decode(Event.EventBody.self, from: body.value).message.type
    }

    /// A thread's event, or `nil` without a topic or an addressable group: a
    /// fabricated thread is indistinguishable from a real one once stored.
    private static func threadChange(_ topic: TopicId, _ change: ThreadChange) -> ChatEvent? {
        guard !topic.topicID.isEmpty, let conversation = conversationID(topic.groupID) else { return nil }
        return .threadChanged(
            threadID: MessageThread.ID(topic.topicID),
            conversationID: conversation,
            change: change
        )
    }

    /// Push 82, `{1 topic, 2 replies, 3 unread}` (§63.10). Field 2 leaves the
    /// first message out; `.counted` counts it, as `replyCount` does.
    ///
    /// **Field 3 counts only when above 0.** It has been seen only as 0, twice,
    /// both on the owner's own replies, so whether it is the unread count is
    /// `[Verify]`. A stored count beats the client's fallback, history's `nil`
    /// keeps it and a read only zeroes it: were field 3 always 0, every thread
    /// it reached would read as read for good. A 0 says nothing until measured.
    private static func topicMetadata(in body: ChannelEventBody) -> ChatEvent? {
        guard case let .topicMetadataUpdatedEvent(event)? = decoded(body),
              event.hasReplyCount else { return nil }
        let claimsUnread = event.hasUnreadReplyCount && event.unreadReplyCount > 0
        let unread = claimsUnread ? Int(event.unreadReplyCount) : nil
        return threadChange(event.topicID, .counted(messages: Int(event.replyCount) + 1, unread: unread))
    }

    /// Push 9: muted means not followed (§64.1, `[Verify]`). Presence decides
    /// (ruling 4); §63.10 saw 0 on topics posted into.
    private static func topicMuteChanged(in body: ChannelEventBody) -> ChatEvent? {
        guard case let .topicMuteChanged(event)? = decoded(body), event.hasMuted else { return nil }
        return threadChange(event.topicID, .followed(!event.muted))
    }

    /// Push 4: a thread viewed, here or on another device (purple's name and
    /// layout, `[Verify]` until a live run). An absent time is 1970, so it is
    /// routed instead (`GROUP_VIEWED`'s rule).
    private static func topicViewed(in body: ChannelEventBody) -> ChatEvent? {
        guard case let .topicViewed(event)? = decoded(body), event.hasViewTime, event.viewTime > 0 else {
            return nil
        }
        return threadChange(event.topicID, .read(upTo: Microseconds.date(event.viewTime)))
    }

    /// Push 53 (body field 46, §64.4): whether a conversation has an unread
    /// thread. Read out of the web client's code, `[Verify]` until a live run.
    private static func unreadThreads(in body: ChannelEventBody) -> ChatEvent? {
        guard case let .groupUnreadThreadStateUpdatedEvent(event)? = decoded(body),
              event.hasHasUnreadThread_p,
              let conversation = conversationID(event.groupID)
        else { return nil }
        return .unreadThreadsChanged(conversationID: conversation, hasUnread: event.hasUnreadThread_p)
    }
}
