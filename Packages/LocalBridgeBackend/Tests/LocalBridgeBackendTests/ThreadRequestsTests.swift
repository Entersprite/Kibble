import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The thread calls no vendored proto names (`findings.md` §64), as bytes: each layout is pinned
/// field by field, because a wrong number is not an error anywhere but on the wire.
struct ThreadRequestsTests {
    private var topic: TopicId {
        var topic = TopicId()
        topic.topicID = "t-1"
        topic.groupID.dmID.dmID = "d-1"
        return topic
    }

    @Test func theWriterEncodesVarintsKeysAndNestedLengths() {
        var writer = ProbeProtoWriter()
        writer.varint(1, 300)
        writer.bool(17, false)
        writer.message(100) { $0.varint(2, 1) }
        // 1: 300 (two varint bytes); 17: false, written all the same (a two-byte key);
        // 100: a two-byte key, length 2, then 2: 1.
        #expect(writer.data == Data([0x08, 0xAC, 0x02, 0x88, 0x01, 0x00, 0xA2, 0x06, 0x02, 0x10, 0x01]))
    }

    @Test func aNegativeInt64IsItsTwosComplement() {
        var writer = ProbeProtoWriter()
        writer.int64(1, -1)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: writer.data) == [UInt64.max])
    }

    @Test func theMuteRequestCarriesTheTopicTheFlagAndAHeader() throws {
        let body = ThreadRequests.muteState(topic, mute: false)
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 2, 100])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: body) == [0])
        let sent = try #require(ProtoFieldScan.payloads(ofField: 1, in: body).first)
        #expect(try TopicId(serializedBytes: sent) == topic)
        #expect(ThreadRequests.muteMethod == "mark_Topic_mute_state")
    }

    @Test func theMetadataRequestIsTheTopicAloneWithNoHeader() throws {
        let body = ThreadRequests.metadata(topic)
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1])
        let sent = try #require(ProtoFieldScan.payloads(ofField: 1, in: body).first)
        #expect(try TopicId(serializedBytes: sent) == topic)
    }

    @Test func aTopicTimeRequestSendsItsMicrosecondsEvenWhenZero() {
        let marked = ThreadRequests.topicTime(topic, micros: 1_700_000_000_000_001)
        #expect(ProtoFieldScan.fields(in: marked).fields.map(\.number) == [1, 2, 100])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: marked) == [1_700_000_000_000_001])
        let cleared = ThreadRequests.topicTime(topic, micros: 0)
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: cleared) == [0])
    }

    @Test func theFollowedThreadsRequestIsHomesThreadsChip() throws {
        let body = ThreadRequests.followedThreads()
        #expect(ProtoFieldScan.fields(in: body).fields.map(\.number) == [1, 2, 4, 4, 4, 4, 4, 4])
        #expect(ProtoFieldScan.varintValues(ofField: 4, in: body) == [4, 2, 5, 6, 7, 3])
        let section = try #require(ProtoFieldScan.payloads(ofField: 2, in: body).first)
        #expect(ProtoFieldScan.fields(in: section).fields.map(\.number) == [1, 4, 9, 10, 11, 15])
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: section) == [30])
        let worldFilter = try #require(ProtoFieldScan.payloads(ofField: 4, in: section).first)
        #expect(ProtoFieldScan.varintValues(ofField: 17, in: worldFilter) == [1])
        let topicFilter = try #require(ProtoFieldScan.payloads(ofField: 9, in: section).first)
        let label = try #require(ProtoFieldScan.payloads(ofField: 2, in: topicFilter).first)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: label) == [1])
        #expect(ProtoFieldScan.varintValues(ofField: 4, in: topicFilter) == [1])
        let option = try #require(ProtoFieldScan.payloads(ofField: 10, in: section).first)
        let replies = try #require(ProtoFieldScan.payloads(ofField: 1, in: option).first)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: replies) == [1])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: replies) == [1])
        let groups = try #require(ProtoFieldScan.payloads(ofField: 2, in: option).first)
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: groups) == [1])
        for field in [11, 15] {
            let sub = try #require(ProtoFieldScan.payloads(ofField: field, in: section).first)
            #expect(ProtoFieldScan.varintValues(ofField: 1, in: sub) == [1])
        }
    }

    @Test func mutedIsFieldTwoAndAbsentIsNil() {
        var writer = ProbeProtoWriter()
        writer.message(1) { $0.int64(1, 5) }
        writer.bool(2, true)
        #expect(ThreadRequests.muted(in: writer.data) == true)
        #expect(ThreadRequests.muted(in: Data()) == nil)
    }

    @Test func aReadBackIsComparedWithWhatWasSent() {
        #expect(ThreadRequests.readBack(nil, sent: 10) == "absent")
        #expect(ThreadRequests.readBack(10, sent: 10) == "equal")
        #expect(ThreadRequests.readBack(7, sent: 10) == "3 µs earlier")
        #expect(ThreadRequests.readBack(12, sent: 10) == "2 µs later")
    }
}
