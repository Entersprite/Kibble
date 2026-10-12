import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    /// Clearing history is monotonic. A stale world must not roll back a
    /// cutoff accepted during this session, even if the DM becomes visible.
    func reconcileHistoryCutoffs(in response: inout PaginatedWorldResponse) {
        for index in response.worldItems.indices {
            guard let id = ChannelEventMapping.conversationID(response.worldItems[index].groupID)
            else { continue }
            let cutoff = max(
                historyCutoffs[id] ?? 0,
                response.worldItems[index].readState.clearHistoryTimestamp_p
            )
            if cutoff > 0 {
                historyCutoffs[id] = cutoff
                response.worldItems[index].readState.clearHistoryTimestamp_p = cutoff
            }
        }
    }

    func retainingUnclearedHistory(
        _ messages: [ChatKit.Message],
        in id: Conversation.ID
    ) -> [ChatKit.Message] {
        guard let cutoff = historyCutoffs[id] else { return messages }
        return messages.filter { Microseconds.from($0.createdAt) > cutoff }
    }
}
