import ChatKit

extension SyncReducer {
    static func reduceConversationActionEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .conversationRemoved(id, before):
            Reduction(
                writes: [.removeConversation(conversation: id, historyBefore: before)],
                effects: [.withdrawAnnouncements(id, upTo: .distantFuture)]
            )
        case let .conversationUnreadMarkChanged(id, at):
            Reduction(writes: [.setConversationUnreadMark(conversation: id, at: at)])
        default: Reduction()
        }
    }
}
