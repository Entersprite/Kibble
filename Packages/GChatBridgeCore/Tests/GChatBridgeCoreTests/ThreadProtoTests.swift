import Foundation
import Testing
@testable import GChatBridgeCore

/// The thread fields the merge names (threads spec §2.1), decoded from bytes and pblite built by
/// hand, so the test does not trust the generated encoder it is checking. Push bodies are pblite:
/// a positional array, or a trailing dictionary for high field numbers (`ChannelEvent`).
struct ThreadProtoTests {
    private func encodeVarint(_ value: UInt64) -> Data {
        var rest = value
        var out = Data()
        while rest >= 0x80 {
            out.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        out.append(UInt8(rest))
        return out
    }

    private func varint(_ field: Int, _ value: UInt64) -> Data {
        encodeVarint(UInt64(field) << 3) + encodeVarint(value)
    }

    private func message(_ field: Int, _ payload: Data) -> Data {
        encodeVarint(UInt64(field) << 3 | 2) + encodeVarint(UInt64(payload.count)) + payload
    }

    private func body(_ value: PBLiteValue) -> Event.EventBody {
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: value)
        #expect(decoded.issues.isEmpty)
        return decoded.message
    }

    /// Field 34 on every reply, history and push alike (`findings.md` §63.3, §63.10).
    @Test func aReplyCarriesFieldThirtyFour() throws {
        let reply = try GChatBridgeCore.Message(serializedBytes: varint(34, 1))
        #expect(reply.hasIsInlineReply)
        #expect(reply.isInlineReply)
        #expect(reply.unknownFields.data.isEmpty)
    }

    /// purple's fields plus 14; a label type purple's enum cannot name survives (Ruling 4).
    @Test func theTopicReadStateFieldsAreNamed() throws {
        let bytes = varint(2, 7) + varint(4, 1) + varint(5, 2) + varint(7, 3) + varint(8, 4)
            + varint(10, 3) + message(11, varint(1, 2) + message(2, Data("k".utf8))) + varint(14, 6)
        let state = try TopicReadState(serializedBytes: bytes)
        #expect(state.lastReadTime == 7)
        #expect(state.unreadMessageCount == 1)
        #expect(state.readMessageCount == 2)
        #expect(state.muteTime == 3)
        #expect(state.updateTimestamp == 4)
        #expect(state.hasTotalMessageCount && state.totalMessageCount == 3)
        #expect(state.topicLabelID.map(\.topicLabelType) == [2])
        #expect(state.hasMarkTopicAsUnreadTime && state.markTopicAsUnreadTime == 6)
        #expect(state.unknownFields.data.isEmpty)
    }

    /// The reply summary no run has seen (§64.7) stays unnamed, so the probe's scan still reaches it.
    @Test func theReplySummaryStaysUnnamed() throws {
        let state = try TopicReadState(serializedBytes: message(13, varint(1, 2)))
        #expect(!state.unknownFields.data.isEmpty)
    }

    @Test func worldFieldTwentySevenAndReadStateTwentyFiveAreNamed() throws {
        let item = try WorldItemLite(serializedBytes: varint(27, 1))
        #expect(item.hasInlineThreadingEnabled && item.inlineThreadingEnabled)
        let state = try GroupReadState(serializedBytes: varint(25, 1))
        #expect(state.hasHasUnreadThread_p && state.hasUnreadThread_p)
    }

    /// Push 4's body at field 4 (purple) `[Verify]`.
    @Test func bodyFieldFourIsATopicViewedEvent() {
        let decoded = body([nil, nil, nil, [[nil, "t-1"], 1_700_000_000_000_000]])
        guard case let .topicViewed(event)? = decoded.type else {
            Issue.record("body field 4 did not decode as topic_viewed")
            return
        }
        #expect(event.topicID.topicID == "t-1")
        #expect(event.viewTime == 1_700_000_000_000_000)
    }

    /// Push 9's body at field 7 (purple) `[Verify]`.
    @Test func bodyFieldSevenIsATopicMuteChangedEvent() {
        let decoded = body([nil, nil, nil, nil, nil, nil, [[nil, "t-1"], true, 5]])
        guard case let .topicMuteChanged(event)? = decoded.type else {
            Issue.record("body field 7 did not decode as topic_mute_changed")
            return
        }
        #expect(event.topicID.topicID == "t-1")
        #expect(event.hasMuted && event.muted)
        #expect(event.eventTime == 5)
    }

    /// Push 82's body at field 64, in the trailing dictionary, as measured (§63.10).
    @Test func bodyFieldSixtyFourIsATopicMetadataUpdatedEvent() {
        let decoded = body([["64": [[nil, "t-1"], 4, 0]]])
        guard case let .topicMetadataUpdatedEvent(event)? = decoded.type else {
            Issue.record("body field 64 did not decode as topic_metadata_updated")
            return
        }
        #expect(event.topicID.topicID == "t-1")
        #expect(event.replyCount == 4)
        #expect(event.hasUnreadReplyCount && event.unreadReplyCount == 0)
    }

    /// Push 53's body at field 46, from the bundle (§64.4) `[Verify]`.
    @Test func bodyFieldFortySixIsAGroupUnreadThreadStateUpdatedEvent() {
        let decoded = body([["46": [nil, true, 2]]])
        guard case let .groupUnreadThreadStateUpdatedEvent(event)? = decoded.type else {
            Issue.record("body field 46 did not decode as group_unread_thread_state_updated")
            return
        }
        #expect(event.hasHasUnreadThread_p && event.hasUnreadThread_p)
        #expect(event.unreadFollowedThreadCount == 2)
    }

    /// The Threads list answers in top-level field 7 (§64.6).
    @Test func theThreadsListAnswerCarriesEntities() throws {
        let topic = message(1, message(1, message(2, Data("t-1".utf8))))
        let entity = topic + message(3, varint(3, 5))
        let answer = try PaginatedWorldResponse(serializedBytes: message(7, entity))
        let only = try #require(answer.worldEntities.first)
        #expect(answer.worldEntities.count == 1)
        #expect(only.hasTopic && only.topic.id.topicID == "t-1")
        #expect(only.hasMessage && only.message.createTime == 5)
    }
}
