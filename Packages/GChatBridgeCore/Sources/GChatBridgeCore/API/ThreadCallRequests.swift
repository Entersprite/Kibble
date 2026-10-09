import Foundation
import SwiftProtobuf

/// The thread calls' requests (threads spec §3), typed. Each layout is the probe's
/// (`ThreadRequests` in LocalBridgeBackend), which `findings.md` §64.7 sent and the server accepted,
/// and `ThreadCallBytesTests` pins every builder to those bytes. The times sent are the caller's:
/// the bridge adds the read position's extra microsecond, or takes one off for an unread mark.
public enum ThreadCallRequests {
    /// `get_user_topic_metadata`: the topic alone, with no request header (§64.1).
    public static func metadata(topic: TopicId) -> GetUserTopicMetadataRequest {
        var request = GetUserTopicMetadataRequest()
        request.topicID = topic
        return request
    }

    /// `mark_Topic_mute_state`. Follow is `mute: false` and Unfollow `mute: true` in the web
    /// client's code (§64.1) `[Verify]`; §64.7 measured the flag round-tripping. Sent even when
    /// false: the field is proto2 `optional`, so presence is part of the value.
    public static func muteState(topic: TopicId, mute: Bool) -> MarkTopicMuteStateRequest {
        var request = MarkTopicMuteStateRequest()
        request.requestHeader = APIRequestHeader.make()
        request.topicID = topic
        request.mute = mute
        return request
    }

    /// `mark_topic_readstate`, read up to `micros` (§64.2). The web client sends the newest
    /// message's own time.
    public static func markRead(topic: TopicId, micros: Int64) -> MarkTopicReadStateRequest {
        var request = MarkTopicReadStateRequest()
        request.requestHeader = APIRequestHeader.make()
        request.topicID = topic
        request.lastReadTime = micros
        return request
    }

    /// `set_topic_unread_timestamp` (§64.3): a message's time minus 1 µs marks the thread unread from
    /// that message; 0 clears the mark, and is sent all the same.
    public static func unreadTimestamp(topic: TopicId, micros: Int64) -> SetTopicUnreadTimestampRequest {
        var request = SetTopicUnreadTimestampRequest()
        request.requestHeader = APIRequestHeader.make()
        request.topicID = topic
        request.unreadTimestamp = micros
        return request
    }

    /// The Threads list: `paginated_world` as Home's Threads chip sends it (§64.6), followed threads
    /// only, newest first, one reply each, plus `fetch_from_user_spaces`, without which §64.7's
    /// answer was empty. With it the answer was empty too: 200, two bytes, no thread (§64.9).
    public static func followedThreads(pageSize: Int32 = 30) -> PaginatedWorldRequest {
        var request = PaginatedWorldRequest()
        request.requestHeader = APIRequestHeader.make()
        request.worldSectionRequests = [followedSection(pageSize: pageSize)]
        request.fetchOptions = [
            .fetchGroupsD3Policies, .fetchBotsInHumanDm, .fetchUserProfilesForGroupNaming,
            .fetchSnippetSenderProfiles, .fetchThreadMessageSenderProfiles, .fetchSpaceIntegrationPayloads
        ]
        request.fetchFromUserSpaces = true
        return request
    }

    /// Whether an answer carries `field`, named or not: acceptance is presence, the shallow check
    /// `create_message` gets (spec §3). A field the proto leaves unnamed is still on the wire, in
    /// `unknownFields`, and serializing re-emits it.
    public static func answer(_ response: some SwiftProtobuf.Message, carries field: Int) -> Bool {
        guard let bytes: Data = try? response.serializedBytes() else { return false }
        return ProtoFieldScan.fields(in: bytes).fields.contains { $0.number == field }
    }

    private static func followedSection(pageSize: Int32) -> WorldSectionRequest {
        var section = WorldSectionRequest()
        section.pageSize = pageSize
        section.worldFilter.excludeAll = true
        var followed = TopicLabelId()
        // purple's THREAD_FOLLOWED.
        followed.topicLabelType = 1
        section.worldTopicFilter.includeTopicLabelID = [followed]
        section.worldTopicFilter.labelFlag = true
        section.worldTopicOption.listMessagesOption.replyPageSize = 1
        section.worldTopicOption.listMessagesOption.replyFlag = true
        section.worldTopicOption.getGroupOption.fetchGroups = true
        section.sort.sortKey = .sortBySortTimeDesc
        section.section.sectionType = .home
        return section
    }
}
