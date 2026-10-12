import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    /// A new main-conversation message makes a hidden conversation visible
    /// again. Reload its authoritative sidebar snapshot before the arrival.
    func reconcileHiddenConversation(_ event: ChatEvent, type: Int?) {
        switch event {
        case let .conversationRemoved(id, before) where type == 16 || type == 32:
            hiddenConversations.insert(id)
            let item = conversationDetails[id]
            if let item, let conversation = WorldMapping.conversation(from: item) {
                emit(.conversationUpdated(conversation))
            }
            hiddenThrough[id] = max(
                hiddenThrough[id] ?? 0,
                item?.sortTimestamp ?? 0,
                item?.readState.lastHeadMessageCreateTimeUsec ?? 0,
                before.map(Microseconds.from) ?? 0
            )
            if let before {
                historyCutoffs[id] = max(historyCutoffs[id] ?? 0, Microseconds.from(before))
            }
        case let .messageReceived(message)
            where !message.isReply && hiddenConversations.contains(message.conversationID):
            if let cutoff = hiddenThrough[message.conversationID] ?? historyCutoffs[message.conversationID],
               Microseconds.from(message.createdAt) <= cutoff {
                return
            }
            hiddenConversations.remove(message.conversationID)
            hiddenThrough[message.conversationID] = nil
            emit(.gap(scope: .everything, reason: "New activity in a hidden conversation."))
        default: break
        }
    }
}

extension LocalBridgeBackend {
    func reconcileHiddenWorld(in response: inout PaginatedWorldResponse) {
        for index in response.worldItems.indices {
            var item = response.worldItems[index]
            guard let id = ChannelEventMapping.conversationID(item.groupID) else { continue }
            if !WorldMapping.isVisible(item), item.readState.hideTimestamp > 0 {
                hiddenConversations.insert(id)
                let previous = hiddenThrough[id] ?? max(
                    item.sortTimestamp,
                    item.readState.lastHeadMessageCreateTimeUsec
                )
                hiddenThrough[id] = max(previous, item.readState.hideTimestamp)
            }
            guard hiddenConversations.contains(id) else { continue }
            if item.readState.lastHeadMessageCreateTimeUsec > (hiddenThrough[id] ?? Int64.max) {
                hiddenConversations.remove(id)
                hiddenThrough[id] = nil
                item.readState.visibleInWorldView = true
                response.worldItems[index] = item
            } else {
                item.readState.visibleInWorldView = false
                response.worldItems[index] = item
            }
        }
    }
}
