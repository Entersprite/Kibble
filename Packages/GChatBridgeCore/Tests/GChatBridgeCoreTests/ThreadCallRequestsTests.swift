import Foundation
import Testing
@testable import GChatBridgeCore

/// The thread calls' typed requests (threads spec §3, `findings.md` §64): what each field means.
/// `ThreadCallBytesTests` in LocalBridgeBackend pins them to the bytes the probe sent (§64.7).
struct ThreadCallRequestsTests {
    private var topic: TopicId {
        var topic = TopicId()
        topic.topicID = "t-1"
        topic.groupID.dmID.dmID = "d-1"
        return topic
    }

    /// The topic alone: no request header, as the web client sends it (§64.1).
    @Test func theMetadataRequestIsTheTopicAlone() throws {
        let request = ThreadCallRequests.metadata(topic: topic)
        #expect(request.topicID == topic)
        let bytes: Data = try request.serializedBytes()
        #expect(ProtoFieldScan.fields(in: bytes).fields.map(\.number) == [1])
    }

    /// Following is `mute: false`, and false is sent, not left out.
    @Test func followingSendsMuteFalseAndAHeader() {
        let request = ThreadCallRequests.muteState(topic: topic, mute: false)
        #expect(request.topicID == topic)
        #expect(request.hasMute && !request.mute)
        #expect(request.requestHeader == APIRequestHeader.make())
    }

    /// The value as given: the bridge owns the read position's extra microsecond.
    @Test func markReadSendsTheMicrosecondsItIsGiven() {
        let request = ThreadCallRequests.markRead(topic: topic, micros: 1_700_000_000_000_001)
        #expect(request.topicID == topic)
        #expect(request.lastReadTime == 1_700_000_000_000_001)
        #expect(request.hasRequestHeader)
    }

    /// 0 clears the mark, and is sent all the same (§64.3).
    @Test func clearingTheUnreadMarkSendsZero() {
        let request = ThreadCallRequests.unreadTimestamp(topic: topic, micros: 0)
        #expect(request.topicID == topic)
        #expect(request.hasUnreadTimestamp && request.unreadTimestamp == 0)
        #expect(request.hasRequestHeader)
    }

    /// Home's Threads chip (§64.6), plus `fetch_from_user_spaces`.
    @Test func theFollowedThreadsRequestIsHomesThreadsChipWithUserSpaces() throws {
        let request = ThreadCallRequests.followedThreads()
        #expect(request.hasRequestHeader)
        #expect(request.fetchFromUserSpaces)
        #expect(request.fetchOptions == [
            .fetchGroupsD3Policies, .fetchBotsInHumanDm, .fetchUserProfilesForGroupNaming,
            .fetchSnippetSenderProfiles, .fetchThreadMessageSenderProfiles, .fetchSpaceIntegrationPayloads
        ])
        #expect(request.worldSectionRequests.count == 1)
        let section = try #require(request.worldSectionRequests.first)
        #expect(section.pageSize == 30)
        #expect(section.worldFilter.excludeAll)
        #expect(section.worldTopicFilter.includeTopicLabelID.map(\.topicLabelType) == [1])
        #expect(section.worldTopicFilter.labelFlag)
        #expect(section.worldTopicOption.listMessagesOption.replyPageSize == 1)
        #expect(section.worldTopicOption.listMessagesOption.replyFlag)
        #expect(section.worldTopicOption.getGroupOption.fetchGroups)
        #expect(section.sort.sortKey == .sortBySortTimeDesc)
        #expect(section.section.sectionType == .home)
    }

    @Test func theThreadsListPageSizeIsAParameter() {
        #expect(ThreadCallRequests.followedThreads(pageSize: 5).worldSectionRequests.first?.pageSize == 5)
    }

    /// The capital T is the web client's own spelling, and the one §64.7 sent.
    @Test func theMethodNamesAreTheWebClients() {
        let metadata: APIMethod<GetUserTopicMetadataRequest, GetUserTopicMetadataResponse> =
            .getUserTopicMetadata
        let mute: APIMethod<MarkTopicMuteStateRequest, MarkTopicMuteStateResponse> = .markTopicMuteState
        let read: APIMethod<MarkTopicReadStateRequest, MarkTopicReadStateResponse> = .markTopicReadState
        let unread: APIMethod<SetTopicUnreadTimestampRequest, SetTopicUnreadTimestampResponse> =
            .setTopicUnreadTimestamp
        #expect(metadata.name == "get_user_topic_metadata")
        #expect(mute.name == "mark_Topic_mute_state")
        #expect(read.name == "mark_topic_readstate")
        #expect(unread.name == "set_topic_unread_timestamp")
    }

    /// Acceptance is presence, named or not (Ruling 3): `{1: {1: 5}, 2: 1}`, as §64.7's mute answer.
    @Test func anAnswerCarriesAFieldItNeverNamed() throws {
        let bytes = Data([0x0A, 0x02, 0x08, 0x05, 0x10, 0x01])
        let answer = try MarkTopicMuteStateResponse(serializedBytes: bytes)
        #expect(ThreadCallRequests.answer(answer, carries: 1))
        #expect(ThreadCallRequests.answer(answer, carries: 2))
        #expect(!ThreadCallRequests.answer(answer, carries: 3))
        #expect(!ThreadCallRequests.answer(MarkTopicMuteStateResponse(), carries: 1))
    }

    /// Mark read's revision is field 2, `{1: int64}`, the field the web client checks (§64.2).
    @Test func markReadsAnswerNamesItsRevision() throws {
        let answer = try MarkTopicReadStateResponse(serializedBytes: Data([0x12, 0x02, 0x08, 0x05]))
        #expect(answer.hasUserRevision)
        #expect(answer.userRevision.timestamp == 5)
    }
}
