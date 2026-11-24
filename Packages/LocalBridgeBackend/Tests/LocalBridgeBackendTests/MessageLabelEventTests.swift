import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessageLabelEventTests {
    @Test(arguments: [68, 69])
    func pinLabelPushInvalidatesOnlyItsAddressedConversation(tag: Int) throws {
        let json = #"[{"56":[[[null,null,null,[null,"thread",[["room"]]]],"original"],null,[2]]}]"#
        let value = try PBLiteValue(json: Data(json.utf8))
        let events = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [
            ChannelEventBody(typeTag: tag, value: value)
        ]))
        #expect(events == [.messagePinsChanged(.init("space/room"))])
        let encoded = try JSONEncoder().encode(events)
        #expect(try JSONDecoder().decode([ChatEvent].self, from: encoded) == events)
    }

    @Test(arguments: [68, 69])
    func personalStarPushNamesTheExactMessage(tag: Int) throws {
        let star = #"[{"56":[[[null,null,null,[null,"thread",[["room"]]]],"original"],null,[1]]}]"#
        let body = try ChannelEventBody(typeTag: tag, value: PBLiteValue(json: Data(star.utf8)))
        let address = MessageAddress(
            conversation: .init("space/room"),
            thread: .init("thread"),
            message: .init("original")
        )
        #expect(ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [body])) == [
            .messageStarChanged(address: address, starred: tag == 68)
        ])
    }

    @Test func binaryCatchUpKeepsThePersonalStarAddress() throws {
        var event = Event()
        event.type = .messageLabelRemoved
        event.body.messageLabelChanged.messageID.messageID = "original"
        event.body.messageLabelChanged.messageID.parentID.topicID.topicID = "thread"
        event.body.messageLabelChanged.messageID.parentID.topicID.groupID.spaceID.spaceID = "room"
        event.body.messageLabelChanged.label.labelType = 1
        let bytes: Data = try event.serializedBytes()
        let recovered = try ChannelEvent(protobuf: Event(serializedBytes: bytes))
        let address = MessageAddress(
            conversation: .init("space/room"),
            thread: .init("thread"),
            message: .init("original")
        )
        #expect(ChannelEventMapping.chatEvents(from: recovered) == [
            .messageStarChanged(address: address, starred: false)
        ])
    }

    @Test func unknownLabelsUnprovenTagsAndIncompleteStarsStayRouted() throws {
        let star = #"[{"56":[[[null,null,null,[null,"thread",[["room"]]]],"original"],null,[1]]}]"#
        let other = star.replacingOccurrences(of: "[1]]", with: "[4]]")
        let missingThread = star.replacingOccurrences(of: #""thread""#, with: "null")
        for (tag, text) in [(68, other), (69, missingThread), (49, star), (85, star)] {
            let body = try ChannelEventBody(typeTag: tag, value: PBLiteValue(json: Data(text.utf8)))
            let events = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [body]))
            #expect(events == [.unknown(type: "googlechat.eventType.\(tag)", payload: JSONValue(body.value))])
        }
    }
}
