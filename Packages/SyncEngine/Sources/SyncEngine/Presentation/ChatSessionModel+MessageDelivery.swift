import ChatKit
import ChatPersistence
import Foundation

struct MessageDeliveryWork {
    var statuses: [Message.ID: MessageDeliveryStatus] = [:]
    var checking: Set<Message.ID> = []
}

extension ChatSessionModel {
    func resetSubmissionWork() {
        sendTasks = [:]
        messageDeliveryWork = MessageDeliveryWork()
    }

    func beginOptimistic(_ message: Message) -> Bool {
        var writes: [StoreWrite] = [.upsertMessage(message)]
        if engine.tracksMessageDelivery {
            writes.append(.beginMessageDelivery(message.id))
        }
        do {
            try store.apply(writes)
            return true
        } catch {
            lastError = error as? ChatError ??
                .unknown("The message could not be saved locally and was not sent.")
            return false
        }
    }

    func watchMessageDeliveries() {
        guard engine.tracksMessageDelivery else { return }
        watch(store.observeMessageDeliveries()) { [weak self] in
            self?.messageDeliveryWork.statuses = Dictionary(uniqueKeysWithValues: $0.map { (
                $0.messageID,
                $0.status
            ) })
        }
    }
}

public extension ChatSessionModel {
    var messageDeliveryStatuses: [Message.ID: MessageDeliveryStatus] {
        messageDeliveryWork.statuses
    }

    var checkingMessageDeliveries: Set<Message.ID> {
        messageDeliveryWork.checking
    }

    func checkMessageDelivery(_ id: Message.ID) {
        guard !watchers.isEmpty, messageDeliveryWork.statuses[id] != nil,
              messageDeliveryWork.checking.count < 8,
              messageDeliveryWork.checking.insert(id).inserted else { return }
        let taskID = UUID()
        sendTasks[taskID] = Task { @MainActor [weak self, engine] in
            defer {
                self?.sendTasks[taskID] = nil
                self?.messageDeliveryWork.checking.remove(id)
            }
            guard !Task.isCancelled else { return }
            await engine.checkMessageDelivery(id)
        }
    }
}
