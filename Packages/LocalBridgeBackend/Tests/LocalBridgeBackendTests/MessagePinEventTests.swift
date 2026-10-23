import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessagePinEventTests {
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

    @Test func personalStarsAndWrongTagsAreNotSharedPins() throws {
        let star = #"[{"56":[[[null,null,null,[null,"thread",[["room"]]]],"original"],null,[1]]}]"#
        let pin = star.replacingOccurrences(of: "[1]]", with: "[2]]")
        for (tag, text) in [(68, star), (7, pin), (85, pin)] {
            let body = try ChannelEventBody(typeTag: tag, value: PBLiteValue(json: Data(text.utf8)))
            guard case .unknown? = ChannelEventMapping.chatEvents(from: ChannelEvent(bodies: [body])).first
            else { Issue.record("A personal star or unrelated event must stay unknown"); return }
        }
    }
}
