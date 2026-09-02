import Foundation
import Testing
@testable import GChatBridgeCore

/// The two send shapes, pinned field by field.
///
/// Every other request family in this package earned a ladder. This one cannot
/// have one - it is a write, and four probe rungs would post four messages into
/// a real conversation - so the reference's shape is pinned here instead, and
/// the tests are what a live run in `findings.md` will be compared against.
struct SendRequestsTests {
    private func spaceGroup(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    /// `client.py:459-470`: request_header, group_id, local_id, text_body,
    /// history_v2, message_info.accept_format_annotations.
    @Test func aNewTopicCarriesTheReferencesSixFields() {
        let request = SendRequests.createTopic(
            group: spaceGroup("s-1"),
            text: "hello",
            localID: "gchat%1"
        )
        #expect(request.hasRequestHeader)
        #expect(request.groupID.spaceID.spaceID == "s-1")
        #expect(request.localID == "gchat%1")
        #expect(request.textBody == "hello")
        #expect(request.historyV2)
        #expect(request.messageInfo.acceptFormatAnnotations)
    }

    /// `reply_to` is `None` on the reference's default path, and in protobuf a
    /// message field that is never assigned is absent rather than empty.
    /// Assigning a default-constructed `SendReplyTarget` would put a field on
    /// the wire that the reference never sends.
    @Test func aNewTopicNamesNoReplyTarget() {
        let request = SendRequests.createTopic(
            group: spaceGroup("s-1"), text: "hi", localID: "l"
        )
        #expect(!request.messageInfo.hasReplyTo)
    }

    /// `client.py:441-457`: the threaded path sends parent_id rather than
    /// group_id, and does **not** set history_v2 - which `CreateMessageRequest`
    /// has no field for at all.
    @Test func aThreadedReplyCarriesItsParentTopic() {
        let request = SendRequests.createMessage(
            group: spaceGroup("s-1"),
            topicID: "t-9",
            text: "reply",
            localID: "gchat%2"
        )
        #expect(request.hasRequestHeader)
        #expect(request.parentID.topicID.topicID == "t-9")
        #expect(request.parentID.topicID.groupID.spaceID.spaceID == "s-1")
        #expect(request.localID == "gchat%2")
        #expect(request.textBody == "reply")
        #expect(request.messageInfo.acceptFormatAnnotations)
    }

    /// `serializedBytes()` and `init(serializedBytes:)` are exact inverses for
    /// both shapes. Every other test here only ever reads the in-memory
    /// struct, so a field-number mistake that only shows up once bytes
    /// actually leave the process would otherwise pass silently.
    @Test func bothShapesRoundTripThroughSerialisation() throws {
        let topic = SendRequests.createTopic(
            group: spaceGroup("s-1"), text: "hello", localID: "l"
        )
        let topicBytes: Data = try topic.serializedBytes()
        let decodedTopic = try CreateTopicRequest(serializedBytes: topicBytes)
        #expect(decodedTopic.textBody == "hello")
        #expect(decodedTopic.localID == "l")

        let message = SendRequests.createMessage(
            group: spaceGroup("s-1"), topicID: "t-1", text: "reply", localID: "l2"
        )
        let messageBytes: Data = try message.serializedBytes()
        let decodedMessage = try CreateMessageRequest(serializedBytes: messageBytes)
        #expect(decodedMessage.textBody == "reply")
        #expect(decodedMessage.localID == "l2")
    }
}
