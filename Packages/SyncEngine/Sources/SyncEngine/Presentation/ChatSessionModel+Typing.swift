import ChatKit
import ChatPersistence
import Foundation

public extension ChatSessionModel {
    func watchConversationActivity() {
        activityWatchTask?.cancel()
        let conversation = selected
        activityWatchTask = Task { [weak self, engine] in
            guard !Task.isCancelled, self?.selected == conversation else { return }
            await engine.watchConversationActivity(conversation)
        }
    }

    func reportTyping(in conversation: Conversation.ID, thread: MessageThread.ID?, active: Bool) {
        guard active else {
            Task { [engine] in await engine.endTyping(in: conversation, thread: thread) }
            return
        }
        guard isActive, selected == conversation, let me,
              thread == nil || threads.openThread == thread,
              let value = conversations.first(where: { $0.id == conversation }) else {
            stopTyping()
            return
        }
        let update = TypingUpdate(conversationID: conversation, threadID: thread, member: me, isTyping: true)
        Task { [weak self, engine] in
            guard self?.isActive == true, self?.selected == conversation,
                  thread == nil || self?.threads.openThread == thread else { return }
            await engine.updateTyping(update, in: value)
        }
    }

    func stopTyping() {
        Task { [engine] in await engine.endTyping() }
    }

    /// These IDs are created by this client's optimistic send path, not parsed provider IDs.
    var pendingMessageIDs: Set<Message.ID> {
        Set(messages.compactMap { message in
            guard let local = message.localID, message.id == Message.ID("local/\(local)") else { return nil }
            return message.id
        })
    }
}
