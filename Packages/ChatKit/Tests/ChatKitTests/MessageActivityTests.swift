import Foundation
import Testing
@testable import ChatKit

struct MessageActivityTests {
    @Test func activityIsOptionalAndFutureValuesSurviveTheMessageWire() throws {
        var message = Message(
            id: .init("message"), conversationID: .init("room"), threadID: .init("thread"),
            sender: .init("peer"), text: "", createdAt: .distantPast
        )
        let encoder = JSONEncoder(); let decoder = JSONDecoder()
        let original = try encoder.encode(message)
        #expect(!String(decoding: original, as: UTF8.self).contains("activity"))
        #expect(try decoder.decode(Message.self, from: original).activity == nil)
        for value in [MessageActivity.pinnedMessage, .pinnedResource, .unknown("future")] {
            message.activity = value
            #expect(try decoder.decode(Message.self, from: encoder.encode(message)) == message)
        }
    }
}
