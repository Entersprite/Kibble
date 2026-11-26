import ChatKit
import GChatBridgeCore

public extension LocalBridgeBackend {
    func blockedConversations() async throws -> [BlockedConversation] {
        let generation = try await blockedListGeneration()
        return try await readBlockedConversations(generation: generation)
    }

    func unblockConversation(_ id: Conversation.ID) async throws -> [BlockedConversation] {
        guard let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.unsupported(capability: "unblockConversation")
        }
        guard unblockingConversations.insert(id).inserted else {
            throw ChatError.unknown("This conversation is already being unblocked.")
        }
        defer { unblockingConversations.remove(id) }
        let generation = try await blockedListGeneration()
        let current = try await readBlockedConversations(generation: generation)
        guard current.contains(where: { $0.id == id }) else { return current }
        try await conversationRPC(BlockedRoomRequests.unblock(group))
        try checkManagementGeneration(generation)
        let confirmed = try await readBlockedConversations(generation: generation)
        guard !confirmed.contains(where: { $0.id == id }) else {
            throw ChatError.decoding("The service did not confirm that the conversation was unblocked.")
        }
        return confirmed
    }
}

extension LocalBridgeBackend {
    func blockedListGeneration() async throws -> Int {
        guard isConnected else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        await delivery.recovery?.value
        try checkManagementGeneration(generation)
        return generation
    }

    private func readBlockedConversations(generation: Int) async throws -> [BlockedConversation] {
        let payload = try await conversationRPCPayload(BlockedRoomRequests.list())
        try checkManagementGeneration(generation)
        let decoded = PBLiteDecoder.decode(BlockedRoomsResponse.self, from: payload)
        guard decoded.issues.allSatisfy({ $0.kind == .unknownField }),
              decoded.message.rooms.count <= 4096 else {
            throw ChatError.decoding("The service returned an invalid blocked-conversations list.")
        }
        var seen = Set<Conversation.ID>()
        return try decoded.message.rooms.map { row in
            let id = Conversation.ID(row.group.id)
            guard row.hasGroup, row.group.id.utf8.count <= 4096, row.name.utf8.count <= 4096,
                  ChannelEventMapping.groupID(for: id) != nil, seen.insert(id).inserted else {
                throw ChatError.decoding("The service returned an invalid blocked conversation.")
            }
            return BlockedConversation(id: id, name: row.name)
        }
    }
}
