import ChatKit
import GChatBridgeCore

/// A provider event with a reference annotation and no inline snapshot. Read the
/// receiving message at its own address to recover a provider-confirmed forward.
/// The annotation payload stays opaque because the live and history encodings differ.
struct SparseForwardTarget: Sendable {
    let id: MessageId
    let createTime: Int64
    let conversation: Conversation.ID

    init?(_ message: GChatBridgeCore.Message, in conversation: Conversation.ID) {
        guard !message.hasReplyTo, message.deleteTime == 0, message.createTime > 0,
              message.messageType != .systemMessage, !message.id.parentID.topicID.topicID.isEmpty,
              message.annotations.contains(where: { $0.type == .replyReference })
        else { return nil }
        id = message.id
        createTime = message.createTime
        self.conversation = conversation
    }

    func matches(_ message: GChatBridgeCore.Message) -> Bool {
        let topic = message.id.parentID.topicID
        return message.id.messageID == id.messageID && topic.topicID == id.parentID.topicID.topicID
            && ChannelEventMapping.conversationID(topic.groupID) == conversation
            && message.createTime == createTime
    }
}

extension LocalBridgeBackend {
    func requestForwardRefetch(_ target: SparseForwardTarget) {
        guard let client = apiClient, forwardRefetches[target.id] == nil, forwardRefetches.count < 16,
              target.createTime > historyCutoffs[target.conversation, default: 0] else { return }
        let generation = directoryGeneration
        forwardRefetches[target.id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let response = try? await client.call(.pinTarget, MessagePinRequests.message(target.id))
            await self?.finishForwardRefetch(target, message: response?.message, generation: generation)
        }
    }

    func forgetForwardRefetches() {
        forwardRefetches.values.forEach { $0.cancel() }
        forwardRefetches.removeAll()
    }

    private func finishForwardRefetch(
        _ target: SparseForwardTarget, message wire: GChatBridgeCore.Message?, generation: Int
    ) {
        guard generation == directoryGeneration else { return }
        forwardRefetches[target.id] = nil
        guard !Task.isCancelled, let wire, target.matches(wire),
              wire.deleteTime == 0, wire.replyTo.referenceType == 2,
              target.createTime > historyCutoffs[target.conversation, default: 0],
              let message = ChannelEventMapping.domainMessage(wire), message.content?.forwarded != nil
        else { return }
        resolveUnknownMembers(Self.referencedMembers(of: message))
        emit(.messageUpdated(message))
    }
}
