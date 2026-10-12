import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func emit(_ event: ChatEvent) {
        switch event {
        case let .messageReceived(message), let .messageUpdated(message):
            if let cutoff = historyCutoffs[message.conversationID],
               Microseconds.from(message.createdAt) <= cutoff {
                return
            }
        default: break
        }
        if case let .conversationUnreadMarkChanged(id, at) = event {
            conversationDetails[id]?.readState.markAsUnreadTimestampUsec = at.map(Microseconds.from) ?? 0
        }
        continuation.yield(event)
    }
}
