import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Every typed thread request serializes to the bytes the probe sent and the server accepted
/// (`findings.md` §64.7), so the proto merge cannot drift from the proven layout without this going
/// red. `APIRequestHeader.make()` is deterministic, so both sides carry the same header. Lives here
/// because the core cannot see the probe.
struct ThreadCallBytesTests {
    private var topic: TopicId {
        var topic = TopicId()
        topic.topicID = "t-1"
        topic.groupID.dmID.dmID = "d-1"
        return topic
    }

    @Test func theMetadataRequestIsTheProbes() {
        #expect(ThreadRequests.bytes(of: ThreadCallRequests.metadata(topic: topic))
            == ThreadRequests.metadata(topic))
    }

    @Test func theMuteRequestIsTheProbesBothWays() {
        for mute in [false, true] {
            #expect(ThreadRequests.bytes(of: ThreadCallRequests.muteState(topic: topic, mute: mute))
                == ThreadRequests.muteState(topic, mute: mute, header: APIRequestHeader.make()))
        }
    }

    @Test func theMarkReadRequestIsTheProbes() {
        let micros: Int64 = 1_700_000_000_000_001
        #expect(ThreadRequests.bytes(of: ThreadCallRequests.markRead(topic: topic, micros: micros))
            == ThreadRequests.topicTime(topic, micros: micros, header: APIRequestHeader.make()))
    }

    /// Both a mark (a time minus 1 µs) and the clear (0).
    @Test func theUnreadRequestIsTheProbesForAMarkAndAClear() {
        for micros: Int64 in [1_699_999_999_999_999, 0] {
            #expect(ThreadRequests.bytes(of: ThreadCallRequests.unreadTimestamp(topic: topic, micros: micros))
                == ThreadRequests.topicTime(topic, micros: micros, header: APIRequestHeader.make()))
        }
    }

    @Test func theThreadsListRequestIsTheProbes() {
        #expect(ThreadRequests.bytes(of: ThreadCallRequests.followedThreads())
            == ThreadRequests.followedThreads(header: APIRequestHeader.make()))
    }

    @Test func theMethodNamesAreTheProbes() {
        let metadata: APIMethod<GetUserTopicMetadataRequest, GetUserTopicMetadataResponse> =
            .getUserTopicMetadata
        let mute: APIMethod<MarkTopicMuteStateRequest, MarkTopicMuteStateResponse> = .markTopicMuteState
        let read: APIMethod<MarkTopicReadStateRequest, MarkTopicReadStateResponse> = .markTopicReadState
        let unread: APIMethod<SetTopicUnreadTimestampRequest, SetTopicUnreadTimestampResponse> =
            .setTopicUnreadTimestamp
        #expect(metadata.name == ThreadRequests.metadataMethod)
        #expect(mute.name == ThreadRequests.muteMethod)
        #expect(read.name == ThreadRequests.markReadMethod)
        #expect(unread.name == ThreadRequests.unreadMethod)
    }
}
