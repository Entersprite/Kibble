import ChatKit
import ChatPersistence
import Foundation

public extension ChatSessionModel {
    /// Destination sends retain the normal operation identity and uncertain-delivery handling.
    func forward(_ id: Message.ID, to destination: Conversation.ID, comment: String) async -> Bool {
        guard capabilities.canSendMessages, capabilities.canForwardMessages, let me,
              conversations.contains(where: { $0.id == destination }),
              let original = try? store.message(id), !original.isDeleted, original.callStatus == nil,
              !id.rawValue.hasPrefix("local/") else { return false }
        var body = capabilities.canFormatMessages
            ? MessageMarkup.parse(ComposedMessage(text: comment)) : ComposedMessage(text: comment)
        var reference = MessageQuote(message: original)
        reference.text = original.text
        body.content = body.content ?? MessageContent()
        body.content?.forwardSource = reference
        let localID = ClientOperationID.make()
        let optimisticID = Message.ID("local/\(localID)")
        var preview = body.content ?? MessageContent()
        preview.forwardSource = nil
        preview.forwarded = ForwardedMessage(
            source: reference, senderName: directory[original.sender]?.displayName,
            senderAvatarURL: directory[original.sender]?.avatarURL, mentions: original.mentions,
            formatting: original.content?.formatting ?? [], attachments: original.attachments,
            links: original.links
        )
        guard beginOptimistic(Message(
            id: optimisticID, conversationID: destination, threadID: MessageThread.ID(""),
            sender: me, text: body.text, createdAt: Date(), localID: localID, mentions: body.mentions,
            content: preview
        )) else { return false }
        didBeginSending?()
        return await submitForward(body, to: destination, localID: localID, optimisticID: optimisticID)
    }
}

private extension ChatSessionModel {
    func submitForward(
        _ body: ComposedMessage, to destination: Conversation.ID, localID: String, optimisticID: Message.ID
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let taskID = UUID()
            sendTasks[taskID] = Task { @MainActor [weak self, engine] in
                defer { self?.sendTasks.removeValue(forKey: taskID) }
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let accepted = await engine.submit(.sendMessage(
                    conversationID: destination, threadID: nil, text: body.text, localID: localID,
                    mentions: body.mentions, content: body.content
                ), undoing: [.removeMessage(id: optimisticID)])
                continuation.resume(returning: accepted)
            }
        }
    }
}
