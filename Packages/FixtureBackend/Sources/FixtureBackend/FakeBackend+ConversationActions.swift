import ChatKit
import Foundation

extension FakeBackend {
    func performConversationAction(_ action: ConversationAction, in id: Conversation.ID) throws {
        try require(capabilities.supports(action), action.wire)
        guard let conversation = world.conversation(id), action.isAvailable(for: conversation.kind) else {
            throw ChatError.unsupported(capability: action.wire)
        }
        if action == .markUnread {
            let at = (conversation.lastActivity ?? world.startedAt).addingTimeInterval(-0.000001)
            try updateConversation(id, emitUpdate: false) {
                $0.markedUnreadAt = at
                $0.hasUnread = true
            }
            emit(.conversationUnreadMarkChanged(conversationID: id, at: at))
        } else {
            let before: Date? = action == .delete ? advance() : nil
            if action == .hide || action == .delete {
                hiddenConversations.insert(id)
                if let before {
                    try updateConversation(id, emitUpdate: false) { $0.historyClearedBefore = before }
                }
            } else {
                if action == .block, conversation.kind == .directMessage {
                    blockedDirectMembers.formUnion(conversation.members.filter { $0 != world.me })
                }
                world.conversations.removeAll { $0.id == id }
            }
            if let before {
                world.messages.removeAll { $0.conversationID == id && $0.createdAt <= before }
            }
            emit(.conversationRemoved(conversationID: id, historyBefore: before))
        }
    }
}
