import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func emit(_ event: ChatEvent) {
        if case let .conversationRemoved(id, _) = event {
            meetingMetadata.targets[id] = nil
            meetingMetadata.cache[id] = nil
            meetingMetadata.pending.removeAll { $0.id == id }
            updateMeetingMetadataLoading()
        }
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
        if case let .readReceiptsChanged(update) = event {
            receiptRevisions[update.conversationID, default: 0] += 1
        }
        continuation.yield(event)
    }
}
