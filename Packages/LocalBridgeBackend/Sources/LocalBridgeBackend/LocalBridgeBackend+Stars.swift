import ChatKit
import GChatBridgeCore

public extension LocalBridgeBackend {
    func starredMessages(after cursor: String?) async throws -> StarredMessagesPage {
        await delivery.recovery?.value
        try Task.checkCancellation()
        guard isConnected, let apiClient else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        let request = try MessageStarRequests.list(after: cursor)
        let response: PaginatedWorldResponse
        do {
            response = try await apiClient.call(.starredMessages, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "loading starred messages")
        }
        try checkManagementGeneration(generation)
        let page = try MessageStarRequests.page(from: response)
        guard page.messages.count <= 30, page.nextCursor == nil || page.nextCursor != cursor else {
            throw ChatError.decoding("Chat returned an invalid page of starred messages.")
        }
        let messages = page.messages.compactMap(ChannelEventMapping.domainMessage)
        guard messages.count == page.messages.count else {
            throw ChatError.decoding("Chat returned an invalid starred message address.")
        }
        var profiles = GetMembersResponse()
        profiles.members = page.messages.map {
            var member = GChatBridgeCore.Member()
            member.user = $0.creator
            return member
        }
        let members = Dictionary(
            MemberMapping.map(profiles).members.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return StarredMessagesPage(
            messages: messages,
            members: Array(members.values),
            nextCursor: page.nextCursor
        )
    }

    func setMessageStarred(_ starred: Bool, at address: MessageAddress) async throws {
        guard isConnected, let apiClient else { throw ChatError.notAuthenticated }
        guard let group = ChannelEventMapping.groupID(for: address.conversation),
              let topic = address.thread?.rawValue, !topic.isEmpty,
              let message = address.message?.rawValue, !message.isEmpty
        else { throw ChatError.decoding("This message cannot be starred.") }
        let id = MessagePinRequests.address(group: group, topic: topic, message: message)
        let generation = directoryGeneration
        do {
            _ = try await readStarTarget(id, using: apiClient, generation: generation)
            if starred {
                _ = try await apiClient.call(.applyMessageLabel, MessageStarRequests.apply(id))
            } else {
                _ = try await apiClient.call(.removeMessageLabel, MessageStarRequests.remove(id))
            }
            try checkManagementGeneration(generation)
            let updated = try await readStarTarget(id, using: apiClient, generation: generation)
            guard MessageStarRequests.isStarred(updated) == starred else {
                throw ChatError.unknown("Chat did not confirm the star change.")
            }
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "updating a starred message")
        }
    }

    private func readStarTarget(
        _ id: MessageId, using client: ProtoAPIClient, generation: Int
    ) async throws -> GChatBridgeCore.Message {
        let response = try await client.call(.pinTarget, MessagePinRequests.message(id))
        try checkManagementGeneration(generation)
        guard response.hasMessage, response.message.id == id, response.message.deleteTime == 0,
              response.message.messageType == .userMessage else {
            throw ChatError.decoding("The original message is unavailable or cannot be starred.")
        }
        return response.message
    }
}
