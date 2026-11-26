import ChatKit
import Foundation

extension SQLiteAccountStorage {
    /// A delayed recovery body cannot overwrite a newer canonical server edit.
    /// Client optimistic edits live in separate replicas and do not enter this comparison.
    func canonicalProviderEvents(_ events: [ChatEvent]) throws -> [ChatEvent] {
        var messages: [Message.ID: Message] = [:]
        var lookedUp = Set<Message.ID>()
        var result: [ChatEvent] = []
        for event in events {
            switch event {
            case let .messageReceived(message), let .messageUpdated(message):
                if lookedUp.insert(message.id)
                    .inserted {
                    messages[message.id] = try projection.message(message.id)
                }
                if let current = messages[message.id], isOlder(message, than: current) {
                    continue
                }
                messages[message.id] = message
            default: break
            }
            result.append(event)
        }
        return result
    }

    private func isOlder(_ message: Message, than current: Message) -> Bool {
        if message.isDeleted {
            return false
        }
        if current.isDeleted {
            return true
        }
        guard let edited = current.editedAt else { return false }
        return message.editedAt.map { $0 < edited } ?? true
    }
}
