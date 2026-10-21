import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func sendReference(
        _ content: MessageContent?,
        in destination: Conversation.ID
    ) async throws -> SendReplyTarget? {
        guard let source = content?.forwardSource else {
            return try MessageContentMapping.target(content?.quote, in: destination)
        }
        guard let client = apiClient,
              let group = ChannelEventMapping.groupID(for: source.conversation),
              !source.thread.rawValue.isEmpty, !source.id.rawValue.isEmpty else {
            throw ChatError.decoding("The original message cannot be addressed.")
        }
        let generation = directoryGeneration
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID.groupID = group
        request.parentID.topicID.topicID = source.thread.rawValue
        request.pageSize = Self.threadPageSize
        let response = try await client.call(.listMessages, request)
        try Task.checkCancellation()
        guard generation == directoryGeneration else { throw CancellationError() }
        guard let original = response.messages.first(where: {
            $0.id.messageID == source.id.rawValue && $0.id.parentID == request.parentID && $0.deleteTime == 0
        }), original.messageType != .systemMessage else {
            throw ChatError
                .decoding("The original message is unavailable. Refresh its conversation and try again.")
        }
        var reference = SendReplyTarget()
        reference.id = original.id
        reference.createTime = original.hasLastUpdateTime ? original.lastUpdateTime : original.createTime
        reference.referenceType = 2
        return reference
    }
}
