import Foundation
import Testing
@testable import ChatKit

struct MessagePinCodingTests {
    @Test func oldCollectionsRefuseWritesAndNewCollectionsRoundTrip() throws {
        let old = try Wire.decode(PinnedMessages.self, from: "{}")
        #expect(old.messages.isEmpty)
        #expect(!old.canModify)
        let value = PinnedMessages(messages: [Fixture.message], members: [], canModify: true)
        let data = try Wire.json(value)
        #expect(try Wire.decode(PinnedMessages.self, from: data) == value)
        #expect(!Capabilities().canReadMessagePins)
    }
}
