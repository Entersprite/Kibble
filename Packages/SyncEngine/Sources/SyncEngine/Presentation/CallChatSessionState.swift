import ChatKit
import Foundation

public struct CallChatSessionState {
    public internal(set) var callID: UUID?
    public internal(set) var conversationID: Conversation.ID?
    public internal(set) var messages: [Message] = []
    public internal(set) var draft = ""
    public internal(set) var isSending = false
    public internal(set) var error: String?
    var savedDrafts: [Conversation.ID: String] = [:]
    var generation = UUID()
    var observer: Task<Void, Never>?
    var loader: Task<Void, Never>?

    mutating func stop(preservingDrafts: Bool = false) {
        observer?.cancel(); loader?.cancel()
        var drafts = savedDrafts
        if let conversationID, !draft.isEmpty {
            drafts[conversationID] = draft
        }
        self = CallChatSessionState()
        if preservingDrafts {
            savedDrafts = drafts
        }
    }
}

public extension ChatSessionModel {
    func openCallChat(in conversation: Conversation.ID, callID: UUID? = nil) {
        let sameScope = callChat.conversationID == conversation && callChat.callID == callID
        guard !sameScope || callChat.observer == nil else { return }
        if !sameScope {
            callChat.stop(preservingDrafts: true)
            callChat.draft = callChat.savedDrafts[conversation] ?? ""
        }
        callChat.conversationID = conversation
        callChat.callID = callID
        let epoch = callChat.generation
        callChat.observer = Task { [weak self, store] in
            do {
                for try await messages in store.observeMessages(in: conversation) {
                    guard let self, !Task.isCancelled, callChat.generation == epoch else { return }
                    callChat.messages = messages
                }
            } catch {
                guard let self, !Task.isCancelled, callChat.generation == epoch else { return }
                callChat.error = "Messages could not be loaded."
            }
        }
        callChat.loader = Task { [weak self, engine] in
            do { try await engine.loadMoreMessages(in: conversation) } catch {
                guard let self, !Task.isCancelled, callChat.generation == epoch else { return }
                callChat.error = "Messages could not be refreshed."
            }
        }
    }

    func closeCallChat(in conversation: Conversation.ID, callID: UUID? = nil) {
        guard callChat.conversationID == conversation, callChat.callID == callID else { return }
        callChat.observer?.cancel(); callChat.loader?.cancel()
        callChat.observer = nil; callChat.loader = nil
    }

    func updateCallChatDraft(_ text: String, in conversation: Conversation.ID, callID: UUID? = nil) {
        guard callChat.conversationID == conversation, callChat.callID == callID,
              !callChat.isSending else { return }
        callChat.draft = text
    }

    func sendCallChat(in conversation: Conversation.ID, callID: UUID? = nil) {
        guard capabilities.canSendMessages, let me, callChat.conversationID == conversation,
              callChat.callID == callID, !callChat.isSending,
              !callChat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = callChat.draft, epoch = callChat.generation
        let localID = ClientOperationID.make()
        let optimisticID = Message.ID("local/\(localID)")
        guard beginOptimistic(Message(
            id: optimisticID, conversationID: conversation, threadID: .init(""), sender: me,
            text: text, createdAt: Date(), localID: localID
        )) else { callChat.error = "The message could not be saved."; return }
        callChat.isSending = true
        callChat.error = nil
        let taskID = UUID()
        sendTasks[taskID] = Task { [weak self, engine] in
            defer { self?.sendTasks[taskID] = nil }
            guard !Task.isCancelled else { return }
            let accepted = await engine.submit(.sendMessage(
                conversationID: conversation, threadID: nil, text: text, localID: localID
            ), undoing: [.removeMessage(id: optimisticID)])
            guard let self, !Task.isCancelled else { return }
            if accepted,
               callChat.savedDrafts[conversation] == text {
                callChat.savedDrafts[conversation] = nil
            }
            guard callChat.generation == epoch else { return }
            callChat.isSending = false
            if accepted {
                callChat.draft = ""
            } else {
                callChat.error = "The message could not be sent. Check its delivery before sending again."
            }
        }
    }
}
