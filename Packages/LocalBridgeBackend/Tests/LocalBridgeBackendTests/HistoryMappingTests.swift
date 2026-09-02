import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `ListTopicsResponse` becoming `[ChatKit.Message]`.
///
/// Same shape as `WorldMappingTests`/`MemberMappingTests`: fixtures built as
/// typed `SwiftProtobuf` values, because `HistoryMapping` runs after
/// `ProtoAPIClient`'s own typed decode. `list_topics` has never been sent by
/// this implementation (`APIMethod.listTopics`'s own doc comment), so every
/// mapping asserted here is a claim about the vendored proto's field
/// numbers, not about a shape observed on the wire - except the reuse of
/// `ChannelEventMapping.domainMessage(_:)` itself, which *is* exercised
/// against real capture shapes in `ChannelEventMappingTests`.
struct HistoryMappingTests {
    // MARK: - Building fixtures in the shape the proto actually uses

    private func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    /// A reply as `Topic.replies` actually carries one: a full `Message`
    /// whose own `id.parent_id.topic_id` names both the topic and the group -
    /// the same identity a `MESSAGE_POSTED` event carries, which is exactly
    /// why `domainMessage(_:)` can be reused unchanged.
    private func reply(
        id: String = "m-1",
        groupID: GroupId,
        topicID: String = "t-1",
        senderID: String = "u-1",
        text: String = "hello",
        createTimeMicros: Int64 = 1_700_000_000_000_000
    ) -> GChatBridgeCore.Message {
        var topic = TopicId()
        topic.groupID = groupID
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic
        var messageID = MessageId()
        messageID.parentID = parent
        if !id.isEmpty {
            messageID.messageID = id
        }
        var creator = User()
        var senderUserID = UserId()
        senderUserID.id = senderID
        creator.userID = senderUserID

        var message = GChatBridgeCore.Message()
        message.id = messageID
        message.creator = creator
        message.textBody = text
        message.createTime = createTimeMicros
        return message
    }

    private func topic(sortTime: Int64 = 0, replies: [GChatBridgeCore.Message]) -> Topic {
        var topic = Topic()
        topic.sortTime = sortTime
        topic.replies = replies
        return topic
    }

    private func response(_ topics: [Topic]) -> ListTopicsResponse {
        var response = ListTopicsResponse()
        response.topics = topics
        return response
    }

    // MARK: - The basic translation

    @Test func aReplyBecomesAMessageWithTheSameIdentityAndText() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [reply(id: "m-1", groupID: group, senderID: "u-1", text: "hello")])
        ]))
        #expect(mapped.messages.count == 1)
        #expect(mapped.messages.first?.id.rawValue == "m-1")
        #expect(mapped.messages.first?.sender.rawValue == "u-1")
        #expect(mapped.messages.first?.text == "hello")
        #expect(mapped.messages.first?.conversationID.rawValue == "space/s-1")
    }

    /// The exact reuse this file exists to prove: microseconds since the
    /// epoch, mapped the same way `ChannelEventMappingTests`'s
    /// `createTimeIsMicrosecondsAndArrivesAsAString` pins for the channel.
    @Test func createTimeIsMicrosecondsTheSameWayTheChannelMapsIt() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [reply(groupID: group, createTimeMicros: 1_700_000_000_000_000)])
        ]))
        #expect(mapped.messages.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Flattening every topic's replies into one list

    @Test func everyTopicsRepliesAreFlattenedIntoOneList() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [
                reply(id: "m-1", groupID: group, topicID: "t-1"),
                reply(id: "m-2", groupID: group, topicID: "t-1")
            ]),
            topic(replies: [reply(id: "m-3", groupID: group, topicID: "t-2")])
        ]))
        #expect(mapped.messages.count == 3)
        #expect(Set(mapped.messages.map(\.id.rawValue)) == ["m-1", "m-2", "m-3"])
    }

    // MARK: - Sorting: ascending by createdAt, regardless of arrival order

    /// The discriminating test for the reversed-topics finding
    /// (`portal.py:428`): built with the *newest* topic first and the
    /// *oldest* last - the shape the reference says the server actually
    /// sends - and asserts the mapped output still comes back
    /// oldest-to-newest, matching `ChatBackend.loadMessages(in:before:)`'s
    /// own contract.
    @Test func messagesAreSortedAscendingByCreatedAtRegardlessOfTopicOrder() {
        let group = spaceGroupID("s-1")
        let oldest = reply(id: "m-old", groupID: group, topicID: "t-1", createTimeMicros: 1000)
        let middle = reply(id: "m-mid", groupID: group, topicID: "t-2", createTimeMicros: 2000)
        let newest = reply(id: "m-new", groupID: group, topicID: "t-3", createTimeMicros: 3000)
        // Arrival order is newest, middle, oldest - reversed from chronology,
        // the shape §20.4/portal.py says the server sends topics in.
        let mapped = HistoryMapping.map(response([
            topic(sortTime: 3000, replies: [newest]),
            topic(sortTime: 2000, replies: [middle]),
            topic(sortTime: 1000, replies: [oldest])
        ]))
        #expect(mapped.messages.map(\.id.rawValue) == ["m-old", "m-mid", "m-new"])
    }

    @Test func aSingleTopicsRepliesAreAlsoSortedByCreatedAt() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [
                reply(id: "m-2", groupID: group, createTimeMicros: 2000),
                reply(id: "m-1", groupID: group, createTimeMicros: 1000)
            ])
        ]))
        #expect(mapped.messages.map(\.id.rawValue) == ["m-1", "m-2"])
    }

    // MARK: - Nothing is silently dropped

    @Test func aReplyWithNoMessageIDIsSkippedAndCounted() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [reply(id: "", groupID: group)])
        ]))
        #expect(mapped.messages.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func aReplyWithAnEmptyGroupIDIsSkippedAndCounted() {
        let mapped = HistoryMapping.map(response([
            topic(replies: [reply(groupID: GroupId())])
        ]))
        #expect(mapped.messages.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func validAndInvalidRepliesAreBothAccountedForInOneRun() {
        let group = spaceGroupID("s-1")
        let mapped = HistoryMapping.map(response([
            topic(replies: [
                reply(id: "m-1", groupID: group),
                reply(id: "", groupID: group),
                reply(id: "m-2", groupID: group),
                reply(groupID: GroupId())
            ])
        ]))
        #expect(mapped.messages.count == 2)
        #expect(mapped.skipped == 2)
    }

    @Test func aTopicWithNoRepliesContributesNothing() {
        let mapped = HistoryMapping.map(response([topic(replies: [])]))
        #expect(mapped.messages.isEmpty)
        #expect(mapped.skipped == 0)
    }

    @Test func anEmptyResponseProducesNoMessagesAndNoSkips() {
        let mapped = HistoryMapping.map(response([]))
        #expect(mapped.messages.isEmpty)
        #expect(mapped.skipped == 0)
    }
}
