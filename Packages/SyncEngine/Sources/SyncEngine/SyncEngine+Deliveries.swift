import ChatKit
import Foundation

extension SyncEngine {
    func handleDelivery(_ delivery: ChatDelivery) async -> Bool {
        guard !Task.isCancelled else { return false }
        do {
            var writes: [StoreWrite] = []
            var effects: [SyncEffect] = []
            for event in delivery.events {
                if case let .conversationRemoved(id, _) = event {
                    invalidateConversationSnapshot(id)
                }
                let reduction = SyncReducer.reduce(event)
                writes += reduction.writes + meetingMetadataWrites(for: event)
                effects += reduction.effects
            }
            let committed: Bool
            if let checkpoint = delivery.checkpoint {
                committed = try store.applyCheckpointed(writes, checkpoint: checkpoint)
            } else {
                try store.apply(writes)
                committed = true
            }
            guard committed else { return true }
            for event in delivery.events {
                processActivity(event)
                if case .conversationsChanged = event {
                    worldLoaded()
                }
            }
            for effect in effects {
                if case .announceArrival = effect, !delivery.isLive || delivery.isSnapshot {
                    continue
                }
                await perform(effect)
            }
            return true
        } catch {
            record(error)
            return false
        }
    }
}
