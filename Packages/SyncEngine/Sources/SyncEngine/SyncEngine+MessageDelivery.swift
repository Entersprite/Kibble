import ChatKit
import ChatPersistence
import Foundation

extension SyncEngine {
    func deliveryUpdates(in undo: [StoreWrite], status: MessageDeliveryStatus) -> [StoreWrite] {
        undo.compactMap { write in
            guard case let .removeMessage(id) = write else { return nil }
            return .setMessageDelivery(id, status)
        }
    }

    func startDeliveryReconciliation(_ pending: [PendingMessageDelivery]) {
        guard tracksMessageDelivery, activityRunning, !pending.isEmpty,
              deliveryReconciliation == nil else { return }
        let generation = managementGeneration
        deliveryReconciliation = Task { [weak self] in
            await self?.reconcileMessageDeliveries(pending, generation: generation)
        }
    }

    private func reconcileMessageDeliveries(_ pending: [PendingMessageDelivery], generation: Int) async {
        defer {
            if generation == managementGeneration {
                deliveryReconciliation = nil
            }
        }
        for delivery in pending where delivery.status != .sent && delivery.status != .failed {
            guard !Task.isCancelled, generation == managementGeneration else { return }
            await checkMessageDelivery(delivery.messageID)
        }
    }
}

public extension SyncEngine {
    func checkMessageDelivery(_ id: Message.ID) async {
        guard let tracked = backend as? any MessageDeliveryTrackingBackend,
              let delivery = try? store.messageDeliveries().first(where: { $0.messageID == id })
        else { return }
        let generation = managementGeneration
        do {
            let status = try await tracked.deliveryStatus(for: delivery.localID)
            guard !Task.isCancelled, generation == managementGeneration else { return }
            try store.apply([.setMessageDelivery(id, status)])
        } catch {
            guard !Task.isCancelled, generation == managementGeneration else { return }
            record(ChatError.unknown("Delivery status is unavailable. The message was not sent again."))
        }
    }
}
