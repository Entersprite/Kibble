import Foundation
import Testing
@testable import GChatBridgeCore

/// A message carrying an upload: purple's annotation
/// (`googlechat_conversation.c:1759-1767`) and mautrix's (`portal.py:1102-1108`)
/// agree on type 13, the metadata, and `chip_render_type = RENDER`, and on
/// nothing else.
struct SendRequestsUploadTests {
    private func group() -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = "s-1"
        group.spaceID = space
        return group
    }

    private func metadata() -> UploadMetadata {
        var metadata = UploadMetadata()
        metadata.attachmentToken = "tok"
        metadata.contentType = "image/png"
        return metadata
    }

    @Test func anUploadAnnotationIsTypeThirteenRenderedAsAChip() {
        let annotation = SendRequests.uploadAnnotation(metadata())
        #expect(annotation.type == .uploadMetadata)
        #expect(annotation.type.rawValue == 13)
        #expect(annotation.uploadMetadata.attachmentToken == "tok")
        #expect(annotation.chipRenderType == .render)
        #expect(!annotation.hasStartIndex)
        #expect(!annotation.hasLength)
    }

    @Test func bothShapesCarryTheAnnotationsTheyAreGiven() {
        let annotation = SendRequests.uploadAnnotation(metadata())
        let topic = SendRequests.createTopic(
            group: group(),
            text: "",
            localID: "l",
            annotations: [annotation]
        )
        let message = SendRequests.createMessage(
            group: group(), topicID: "t", text: "caption", localID: "l", annotations: [annotation]
        )
        #expect(topic.annotations == [annotation])
        #expect(topic.textBody == "")
        #expect(message.annotations == [annotation])
        #expect(message.textBody == "caption")
    }

    @Test func aTextMessageStillCarriesNone() {
        #expect(SendRequests.createTopic(group: group(), text: "hi", localID: "l").annotations.isEmpty)
    }
}
