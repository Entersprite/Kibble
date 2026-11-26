import ChatKit

extension Fixture {
    static var historyEvent: ChatEvent {
        do {
            return try .historyLoaded(MessageHistoryUpdate(
                messages: [message],
                conversationID: message.conversationID
            ))
        } catch {
            return .unknown(type: "invalidHistoryFixture", payload: .null)
        }
    }
}
