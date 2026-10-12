import ChatKit
import Foundation

public extension ChatSessionModel {
    /// Serializes against an already scheduled receipt, and holds automatic
    /// receipts after Mark as Unread until the conversation is reopened.
    func perform(_ action: ConversationAction, in id: Conversation.ID) {
        guard capabilities.supports(action), conversationActionTasks[id] == nil,
              let conversation = conversations.first(where: { $0.id == id }),
              action.isAvailable(for: conversation.kind) else { return }
        conversationActionError = nil
        lastError = nil
        let previousRead = markTasks[id]
        let generation = UUID()
        conversationActionGenerations[id] = generation
        if action == .markUnread {
            unreadHolds.insert(id)
        }
        conversationActionTasks[id] = Task { @MainActor [weak self] in
            await previousRead?.value
            guard let self, !Task.isCancelled else { return }
            defer {
                if conversationActionGenerations[id] == generation {
                    conversationActionTasks[id] = nil
                    conversationActionGenerations[id] = nil
                }
            }
            let failure = await engine.submitConversationAction(action, in: id)
            guard !Task.isCancelled else { return }
            if failure == nil {
                published[id] = nil
                if action != .markUnread, selected == id {
                    clearSelection()
                }
            } else {
                conversationActionError = failure
                lastError = failure
                if action == .markUnread {
                    unreadHolds.remove(id)
                }
            }
        }
    }
}

extension ChatSessionModel {
    func isManuallyUnread(_ id: Conversation.ID) -> Bool {
        // Ordinary arrivals must not synchronously wait on the store queue.
        // Read it only for a known manual mark, to avoid re-arming from an
        // observation that has not yet delivered the mark's accepted clear.
        guard conversations.first(where: { $0.id == id })?.markedUnreadAt != nil else { return false }
        return (try? store.hasManualUnreadMark(in: id)) == true
    }

    func readPositionClearingUnreadMark(_ position: Date, in id: Conversation.ID) -> Date {
        guard (try? store.hasManualUnreadMark(in: id)) == true,
              let read = try? store.lastReadAt(id) else { return position }
        return max(position, read)
    }
}
