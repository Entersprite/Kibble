import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func emit(_ event: ChatEvent) {
        guard prepareEvent(event) else { return }
        if delivery.running {
            enqueueProviderBatch(.init(events: [event]))
        } else {
            continuation.yield(event)
        }
    }

    func emitCommitted(_ event: ChatEvent) async -> Bool {
        if !delivery.running {
            emit(event); return !Task.isCancelled
        }
        guard !Task.isCancelled, prepareEvent(event) else { return false }
        do {
            try await submitProviderBatch(.init(events: [event]))
            return true
        } catch { return false }
    }

    func prepareEvent(_ event: ChatEvent) -> Bool {
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
                return false
            }
        default: break
        }
        if case let .conversationUnreadMarkChanged(id, at) = event {
            conversationDetails[id]?.readState.markAsUnreadTimestampUsec = at.map(Microseconds.from) ?? 0
        }
        if case let .readReceiptsChanged(update) = event {
            receiptRevisions[update.conversationID, default: 0] += 1
        }
        return true
    }
}
