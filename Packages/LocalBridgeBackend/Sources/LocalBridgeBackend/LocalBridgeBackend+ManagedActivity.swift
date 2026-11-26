import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend: ManagedChatActivityBackend {
    public func setReceiveInterests(
        presenceMembers: Set<ChatKit.Member.ID>, conversations: Set<Conversation.ID>
    ) async throws {
        let groups = conversations.sorted { $0.rawValue < $1.rawValue }
            .compactMap(ChannelEventMapping.groupID)
        guard groups.count == conversations.count else {
            throw ChatError.unsupported(capability: "conversationActivity")
        }
        let generation = directoryGeneration
        let previous = presencePoll.allPeople
        presencePoll.clientPeople = presenceMembers
        let added = presencePoll.allPeople.subtracting(previous)
        if let apiClient, !added.isEmpty, presencePoll.task != nil {
            await pollPresence(
                added.sorted { $0.rawValue < $1.rawValue },
                using: apiClient,
                generation: generation
            )
        }
        guard !Task.isCancelled, generation == directoryGeneration else { return }
        await channel?.watchGroups(groups)
    }
}
