import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func pinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        do {
            return try await readPinnedMessages(in: conversation)
        } catch {
            diagnostics.record(.messagePinsFailed(failure: ManagementFailureKind.of(error)))
            throw error
        }
    }

    private func readPinnedMessages(in conversation: Conversation.ID) async throws -> PinnedMessages {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: conversation)
        else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        let canModify = try await pinPermission(group, generation: generation)
        let response = try await apiClient.call(.listMessages, MessagePinRequests.list(in: group))
        try checkManagementGeneration(generation)
        guard response.messages.count <= 100 else {
            throw ChatError.decoding("The service returned too many pinned messages.")
        }
        let messages = response.messages.compactMap(ChannelEventMapping.domainMessage)
        guard messages.count == response.messages.count,
              Set(messages.map(\.id)).count == messages.count,
              messages.allSatisfy({ $0.conversationID == conversation && !$0.isDeleted }),
              response.messages.allSatisfy({ $0.id.parentID.topicID.groupID == group })
        else { throw ChatError.decoding("The service returned invalid pinned messages.") }
        var profiles = GetMembersResponse()
        profiles.members = response.messages.map {
            var member = GChatBridgeCore.Member(); member.user = $0.creator; return member
        }
        let members = Dictionary(
            MemberMapping.map(profiles).members.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return PinnedMessages(messages: messages, members: Array(members.values), canModify: canModify)
    }

    func setMessagePinned(_ pinned: Bool, at address: MessageAddress) async throws -> PinnedMessages {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: address.conversation),
              let topic = address.thread?.rawValue, !topic.isEmpty,
              let message = address.message?.rawValue, !message.isEmpty
        else { throw ChatError.decoding("This message cannot be pinned.") }
        let generation = directoryGeneration
        guard try await pinPermission(group, generation: generation) else {
            throw ChatError.unknown("You do not have permission to change this conversation's pins.")
        }
        let id = MessagePinRequests.address(group: group, topic: topic, message: message)
        let target = try await apiClient.call(.pinTarget, MessagePinRequests.message(id))
        try checkManagementGeneration(generation)
        guard target.hasMessage, target.message.id == id,
              target.message.deleteTime == 0, target.message.messageType == .userMessage
        else { throw ChatError.decoding("The original message is unavailable or cannot be pinned.") }
        if pinned {
            _ = try await apiClient.call(.applyPin, MessagePinRequests.apply(id))
        } else {
            _ = try await apiClient.call(.removePin, MessagePinRequests.remove(id))
        }
        try checkManagementGeneration(generation)
        let confirmed = try await pinnedMessages(in: address.conversation)
        guard confirmed.messages.contains(where: { $0.id.rawValue == message }) == pinned else {
            throw ChatError
                .unknown("The service did not confirm the pin change. Refresh pins before retrying.")
        }
        return confirmed
    }
}

extension LocalBridgeBackend {
    private func pinPermission(_ group: GroupId, generation: Int) async throws -> Bool {
        guard let apiClient else { throw ChatError.notAuthenticated }
        await selfIdentification?.value
        try checkManagementGeneration(generation)
        guard let me = calendarPoll.me else { throw ChatError.notAuthenticated }
        let response = try await apiClient.call(
            .managementDetails,
            ConversationManagementRequests.details(group)
        )
        try checkManagementGeneration(generation)
        guard response.hasGroup, response.group.groupID == group,
              response.membershipState == .memberJoined else {
            throw ChatError.unknown("This conversation is unavailable.")
        }
        let permissions = try await managementPermissions(group, user: me.rawValue, generation: generation)
        return ManagementMapping.grants(permissions, 59)
    }
}
