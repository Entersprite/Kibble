import ChatKit
import ChatPersistence
import Foundation

public extension ChatSessionModel {
    /// Destination sends retain the normal operation identity and uncertain-delivery handling.
    func forward(_ id: Message.ID, to destination: Conversation.ID, comment: String) async -> Bool {
        guard capabilities.canSendMessages, capabilities.canForwardMessages, let me,
              let original = forwardSource(id, to: destination) else { return false }
        let body = forwardBody(original, comment: comment)
        guard let reference = body.content?.forwardSource else { return false }
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

    func scheduleForward(_ id: Message.ID, to destination: Conversation.ID, comment: String, at time: Date)
        async -> Bool {
        let address = MessageAddress(conversation: destination)
        guard capabilities.canScheduleForwards, isClientTransportAvailable,
              let original = forwardSource(id, to: destination),
              schedules.submissions.insert(address).inserted else { return false }
        let body = forwardBody(original, comment: comment)
        return await withCheckedContinuation { continuation in
            schedules.creates[address] = Task { @MainActor [weak self, engine] in
                defer {
                    self?.schedules.creates[address] = nil
                    self?.schedules.submissions.remove(address)
                }
                do {
                    _ = try await engine.changeSchedule(.create(address, body, time, converting: nil))
                    guard !Task.isCancelled else { continuation.resume(returning: false); return }
                    self?.refreshScheduledMessages()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

private extension ChatSessionModel {
    func forwardSource(_ id: Message.ID, to destination: Conversation.ID) -> Message? {
        guard conversations.contains(where: { $0.id == destination }),
              let original = try? store.message(id), !original.isDeleted, original.callStatus == nil,
              !id.rawValue.hasPrefix("local/") else { return nil }
        return original
    }

    func forwardBody(_ original: Message, comment: String) -> ComposedMessage {
        var body = capabilities.canFormatMessages
            ? MessageMarkup.parse(ComposedMessage(text: comment)) : ComposedMessage(text: comment)
        var reference = MessageQuote(message: original)
        reference.text = original.text
        body.content = body.content ?? MessageContent()
        body.content?.forwardSource = reference
        return body
    }

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
