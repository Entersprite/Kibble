import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

struct MessagePinRequestsTests {
    @Test func labelFilterAndMutationsUseTheSharedPinWireFields() throws {
        var group = GroupId(); group.spaceID.spaceID = "room"
        let request = MessagePinRequests.list(in: group)
        let filter = try request.filter.serializedData()
        #expect(filter == Data([0x42, 0x02, 0x08, 0x02, 0x48] + Array(repeating: 0xFF, count: 9) + [0x01]))
        let id = MessagePinRequests.address(group: group, topic: "thread", message: "original")
        let apply = MessagePinRequests.apply(id)
        let remove = MessagePinRequests.remove(id)
        #expect(try apply.label.serializedData() == Data([0x08, 0x02, 0x18, 0x00]))
        #expect(try remove.label.serializedData() == apply.label.serializedData())
        #expect(apply.messageID == id && remove.messageID == id)
        #expect(apply.hasRequestHeader && remove.hasRequestHeader && request.hasRequestHeader)
    }
}
