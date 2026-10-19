import ChatKit
import Foundation
import Testing

struct HistoryProjectionTests {
    @Test func scopedHistoryRejectsForeignRowsAndUnscopedCompleteness() throws {
        let message = Fixture.message
        #expect(throws: ChatError.self) {
            try MessageHistoryUpdate(messages: [message], conversationID: Conversation.ID("foreign"))
        }
        #expect(throws: ChatError.self) {
            try MessageHistoryUpdate(
                messages: [message],
                conversationID: message.conversationID,
                threadID: MessageThread.ID("foreign")
            )
        }
        #expect(throws: ChatError.self) {
            try MessageHistoryUpdate(messages: [], conversationID: message.conversationID, isComplete: true)
        }
    }

    @Test func decoderEnforcesHistoryScopeRatherThanTrustingTheEncoder() throws {
        let update = try MessageHistoryUpdate(
            messages: [Fixture.message],
            conversationID: Fixture.message.conversationID
        )
        let encoded = try JSONEncoder().encode(update)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["conversationID"] = "foreign"
        let forged = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MessageHistoryUpdate.self, from: forged)
        }
    }

    @Test func completeThreadHistoryAndProgressRoundTrip() throws {
        let history = try MessageHistoryUpdate(
            messages: [Fixture.message], conversationID: Fixture.message.conversationID,
            threadID: Fixture.message.threadID, isComplete: true
        )
        let events: [ChatEvent] = [.historyLoaded(history), .mentionBackfillChanged(.init(running: true))]
        for event in events {
            #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(event)) == event)
        }
    }
}
