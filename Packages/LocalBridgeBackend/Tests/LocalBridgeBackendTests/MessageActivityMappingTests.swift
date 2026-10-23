import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessageActivityMappingTests {
    @Test func boardMetadataSuppliesActivityAndTheInitiatorWithoutGuessingFromText() throws {
        let update = try PBLiteDecoder.decode(
            RoomUpdatedMetadata.self,
            fromJSON: Data(#"[null,null,null,[["actor"]],null,null,null,null,[1,1]]"#.utf8)
        )
        #expect(update.issues.isEmpty)
        var annotation = Annotation(); annotation.roomUpdated = update.message
        var wire = GChatBridgeCore.Message()
        wire.id = MessagePinRequests.address(
            group: WorldItemFixture.spaceGroupID("a"), topic: "thread", message: "activity"
        )
        wire.creator.userID.id = "system"; wire.annotations = [annotation]
        let message = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(message.activity == .pinnedMessage && message.sender.rawValue == "actor")
        #expect(message.text.isEmpty)
        wire.annotations = []; wire.textBody = "Alex pinned a message"
        #expect(ChannelEventMapping.domainMessage(wire)?.activity == nil)
        annotation.roomUpdated.boardAction.targetType = 2
        #expect(MessageActivityMapping.pin(in: [annotation])?.activity == .pinnedResource)
        annotation.roomUpdated.clearInitiator()
        #expect(MessageActivityMapping.pin(in: [annotation])?.activity == .pinnedResource)
        #expect(MessageActivityMapping.pin(in: [annotation])?.sender == nil)
        annotation.roomUpdated.boardAction.action = 99
        #expect(MessageActivityMapping.pin(in: [annotation]) == nil)
    }
}
