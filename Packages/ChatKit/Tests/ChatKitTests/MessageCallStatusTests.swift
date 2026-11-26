import Foundation
import Testing
@testable import ChatKit

struct MessageCallStatusTests {
    @Test func callStatusHasAnAdditiveStableWireShape() throws {
        var message = try Wire.decode(Message.self, from: Golden.load("message"))
        #expect(message.callStatus == nil)
        message.callStatus = .missed
        try expectWireStable(message, golden: "message-call-missed")
        message.callStatus = .unknown("future-status")
        let json = try Wire.json(message)
        #expect(json.contains("\"callStatus\":\"future-status\""))
        #expect(try Wire.decode(Message.self, from: json) == message)
    }

    @Test func absenceKeepsOlderMessagesByteIdenticalAndWordsDoNotClassifyACall() throws {
        var message = try Wire.decode(Message.self, from: Golden.load("message"))
        try expectWireStable(message, golden: "message")
        message.text = "Call started"
        #expect(try Wire.decode(Message.self, from: Wire.json(message)).callStatus == nil)
    }
}
