import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct UnsentMessageEventTests {
    @Test func liveBodyOnlyExportsTheExactComposerAddress() throws {
        let value = try PBLiteValue(json: Data(
            #"[{"12":87,"67":[[["draft",[["room"]],"topic"],null,null,"private draft text",null,null,2]]}]"#
                .utf8
        ))
        let events = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [
            ChannelEventBody(typeTag: 87, value: value)
        ]))
        let address = ComposerDraftAddress(conversation: .init("space/room"), thread: .init("topic"))
        #expect(events == [.unsentMessagesChanged(.init(address: address, drafts: true, scheduled: false))])
        let encoded = try JSONEncoder().encode(events)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private draft text"))
    }

    @Test func binaryConversionAndIdentityOnlyDeletionInvalidateBothCollections() throws {
        var event = Event()
        event.type = .unsentMessageUpdated
        event.body.unsentMessageChanged.message.id.localID = "draft"
        event.body.unsentMessageChanged.message.id.groupID.spaceID.spaceID = "room"
        event.body.unsentMessageChanged.message.unsentType = 1
        var deletion = event.body
        deletion.eventType = .unsentMessageDeleted
        deletion.unsentMessageChanged.message.clearUnsentType()
        event.bodies = [deletion]

        let bytes: Data = try event.serializedBytes()
        let recovered = try ChannelEvent(protobuf: Event(serializedBytes: bytes))
        let address = ComposerDraftAddress(conversation: .init("space/room"))
        let change = ChatEvent.unsentMessagesChanged(.init(address: address, drafts: true, scheduled: true))
        #expect(ChannelEventMapping.chatEvents(from: recovered) == [change, change])
    }
}
