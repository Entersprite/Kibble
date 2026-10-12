import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func openDirectConversation(with member: ChatKit.Member.ID) async throws -> Conversation {
        do {
            return try await loadDirectConversation(with: member)
        } catch let error as APIFailure {
            throw Self.chatError(fromAPI: error, call: "opening a direct conversation")
        }
    }
}

private extension LocalBridgeBackend {
    func loadDirectConversation(with member: ChatKit.Member.ID) async throws -> Conversation {
        guard isConnected, let apiClient else { throw ChatError.notAuthenticated }
        _ = try await loadConversations()
        try Task.checkCancellation()
        await selfIdentification?.value
        try Task.checkCancellation()
        guard let me = calendarPoll.me, member != me, !member.rawValue.isEmpty else {
            throw ChatError.unknown("Choose another person to start a conversation.")
        }
        if let item = conversationDetails.values.first(where: {
            let kind = WorldMapping.kind(for: $0)
            return (kind == .directMessage || kind == .appDirectMessage)
                && $0.dmMembers.members.contains { $0.id == member.rawValue }
        }) {
            guard !item.readState.blocked,
                  !item.readState.hasMembershipState || item.readState.membershipState != .memberNotAMember,
                  let conversation = WorldMapping.conversation(from: item) else {
                throw ChatError.unknown("This conversation is blocked or unavailable.")
            }
            return try await restoreDirectConversation(conversation, group: item.groupID, using: apiClient)
        }
        let response = try await apiClient.call(
            .createDm,
            DirectConversationRequests.create(userID: member.rawValue)
        )
        try Task.checkCancellation()
        guard response.hasDm, case let .dmID(dm) = response.dm.groupID.id, !dm.dmID.isEmpty,
              let id = ChannelEventMapping.conversationID(response.dm.groupID) else {
            throw ChatError.decoding("The service did not return a direct conversation.")
        }
        // Some providers return an existing hidden DM from create_dm.
        // Explicitly restore its visibility before presenting it.
        let conversation = Conversation(id: id, kind: .directMessage, members: [me, member])
        return try await restoreDirectConversation(
            conversation,
            group: response.dm.groupID,
            using: apiClient
        )
    }
}

extension LocalBridgeBackend {
    private func restoreDirectConversation(
        _ conversation: Conversation, group: GroupId, using client: ProtoAPIClient
    ) async throws -> Conversation {
        let response = try await client.call(
            .hideGroup,
            ConversationActionRequests.hide(group: group, hidden: false)
        )
        try Task.checkCancellation()
        guard response.hasReadState || response.hasUserRevision else {
            throw ChatError.decoding("The service did not confirm opening the conversation.")
        }
        hiddenConversations.remove(conversation.id)
        hiddenThrough[conversation.id] = nil
        var conversation = conversation
        if let cutoff = historyCutoffs[conversation.id] {
            conversation.historyClearedBefore = Microseconds.date(cutoff)
        }
        return conversation
    }
}
