import ChatKit

enum MessageCollectionChange: Sendable {
    case unsent(UnsentMessagesChange)
    case star(address: MessageAddress, starred: Bool)
    case conversationSections
    case refreshAll
}

extension SyncEngine {
    func publishMessageCollectionChanges(in delivery: ChatDelivery) {
        if delivery.isSnapshot {
            conversationSectionVersion += 1
            messageCollectionChangeSink.yield(.refreshAll)
        }
        for event in delivery.events {
            publishMessageCollectionChange(for: event)
        }
    }

    func publishMessageCollectionChange(for event: ChatEvent) {
        let change: MessageCollectionChange
        switch event {
        case let .unsentMessagesChanged(unsent):
            change = .unsent(unsent)
        case let .messageStarChanged(address, starred):
            change = .star(address: address, starred: starred)
        case let .conversationSectionsChanged(removedSectionID, _):
            guard backend.capabilities.canReadConversationSections else { return }
            if let removedSectionID, !removedSectionID.isEmpty, removedSectionID.utf8.count <= 512 {
                pendingConversationSectionRemovals.insert(removedSectionID)
            }
            conversationSectionVersion += 1
            change = .conversationSections
        case .historyInvalidated, .gap(scope: .everything, reason: _):
            conversationSectionVersion += 1
            change = .refreshAll
        default:
            return
        }
        if case .dropped = messageCollectionChangeSink.yield(change) {
            messageCollectionChangeSink.yield(.refreshAll)
        }
    }

    func takeConversationSectionRemovals() -> Set<String> {
        defer { pendingConversationSectionRemovals.removeAll() }
        return pendingConversationSectionRemovals
    }
}
