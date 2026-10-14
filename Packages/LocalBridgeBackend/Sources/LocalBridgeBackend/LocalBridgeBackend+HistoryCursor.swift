import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// Google names a topic after its root message. For an unknown cached
    /// root, a one-message oldest-first listing supplies the exact timestamp
    /// without reading the entire thread. The response must prove that root's
    /// identity and parent; an absent cursor never falls back to newest history.
    func historyCursorAnchor(
        _ before: ChatKit.Message.ID?, in conversation: Conversation.ID, group: GroupId,
        client: ProtoAPIClient, generation: Int
    ) async throws -> Int64? {
        try requireHistorySession(generation)
        guard let before else { return nil }
        if let known = messageTimes.micros(of: before) {
            return known
        }
        guard !before.rawValue.isEmpty else {
            throw ChatError.unknown("A backward history request needs a nonempty message cursor")
        }
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID.groupID = group
        request.parentID.topicID.topicID = before.rawValue
        request.pageSize = 1
        let response: ListMessagesResponse
        do {
            response = try await client.call(.listMessages, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the history cursor /api/ list_messages call")
        }
        try requireHistorySession(generation)
        guard response.messages.count == 1, let wire = response.messages.first,
              wire.id.messageID == before.rawValue,
              wire.id.parentID.topicID.topicID == before.rawValue,
              wire.hasCreateTime, wire.createTime > 0,
              let root = ChannelEventMapping.domainMessage(wire),
              root.conversationID == conversation, !root.isReply else {
            throw ChatError.unknown("The cached history cursor could not be resolved to its original root")
        }
        messageTimes.remember([root])
        return wire.createTime
    }

    /// A delayed response must not populate a replacement session's time cache
    /// or emit thread state. Disconnect advances the directory generation.
    func requireHistorySession(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isConnected, apiClient != nil, generation == directoryGeneration else {
            throw CancellationError()
        }
    }
}
