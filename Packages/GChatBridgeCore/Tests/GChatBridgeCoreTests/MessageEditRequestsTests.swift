import Foundation
import Testing
@testable import GChatBridgeCore

/// `edit_message` and `delete_message`, shaped as maugclib builds them
/// (`client.py:367-410`). `[Verify]` until `--probe=edit` runs (edit spec §1).
struct MessageEditRequestsTests {
    private func space(_ id: String) -> GroupId {
        var group = GroupId()
        group.spaceID.spaceID = id
        return group
    }

    @Test func anEditNamesTheMessageByGroupTopicAndID() {
        let request = MessageEditRequests.editMessage(
            group: space("s-1"), topicID: "t-1", messageID: "m-1", text: "fixed", annotations: []
        )
        #expect(request.hasRequestHeader)
        #expect(request.messageID.parentID.topicID.groupID.spaceID.spaceID == "s-1")
        #expect(request.messageID.parentID.topicID.topicID == "t-1")
        #expect(request.messageID.messageID == "m-1")
        #expect(request.textBody == "fixed")
    }

    /// The reference sets it, so Google formats the text as it does a send's.
    @Test func anEditAcceptsFormatAnnotations() {
        let request = MessageEditRequests.editMessage(
            group: space("s-1"), topicID: "t-1", messageID: "m-1", text: "fixed", annotations: []
        )
        #expect(request.messageInfo.acceptFormatAnnotations)
    }

    @Test func anEditCarriesItsAnnotations() {
        let mention = SendRequests.mentionAllAnnotation(start: 0, length: 4)
        let request = MessageEditRequests.editMessage(
            group: space("s-1"), topicID: "t-1", messageID: "m-1", text: "@all", annotations: [mention]
        )
        #expect(request.annotations == [mention])
    }

    @Test func aDeleteNamesTheMessageAndNothingElse() {
        let request = MessageEditRequests.deleteMessage(group: space("s-1"), topicID: "t-1", messageID: "m-1")
        #expect(request.hasRequestHeader)
        #expect(request.messageID.messageID == "m-1")
        #expect(request.messageID.parentID.topicID.topicID == "t-1")
        #expect(request.messageID.parentID.topicID.groupID.spaceID.spaceID == "s-1")
    }

    @Test func theMethodsAreNamedAsTheWebClientNamesThem() {
        #expect(APIMethod.editMessage.name == "edit_message")
        #expect(APIMethod.deleteMessage.name == "delete_message")
    }

    @Test func anEditRoundTripsThroughSerialisation() throws {
        let request = MessageEditRequests.editMessage(
            group: space("s-1"), topicID: "t-1", messageID: "m-1", text: "fixed", annotations: []
        )
        let bytes: Data = try request.serializedBytes()
        #expect(try EditMessageRequest(serializedBytes: bytes) == request)
    }
}
