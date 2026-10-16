import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func browseSpaces(
        _ query: SpaceDirectoryQuery,
        after cursor: String?
    ) async throws -> SpaceDirectoryPage {
        guard isConnected, let apiClient else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        let key = "spaces:\(generation):\(query.scope.type):\(query.organization.type):\(query.text)"
        let token = try ManagementCursor.decode(cursor, key: key)
        guard [.all, .internalOnly, .externalOnly].contains(query.organization) else {
            throw ChatError.unsupported(capability: "spaceDirectoryOrganization")
        }
        if [.all, .joined, .discover].contains(query.scope) {
            return try await discoverManagementSpaces(
                query, token: token, key: key, generation: generation, client: apiClient
            )
        }
        if query.scope == .invitations || query.scope == .spamInvitations {
            guard token == nil else { throw ChatError.decoding("Reload your invitations.") }
            return try await managementInvitations(
                query.text, spam: query.scope == .spamInvitations, generation: generation, client: apiClient
            )
        }
        throw ChatError.unsupported(capability: "spaceDirectoryScope")
    }

    private func managementInvitations(
        _ text: String, spam: Bool, generation: Int, client apiClient: ProtoAPIClient
    )
        async throws -> SpaceDirectoryPage {
        let response = try await apiClient.call(
            .listInvitedRooms,
            ConversationManagementRequests.invitations(spam: spam)
        )
        try checkManagementGeneration(generation)
        var spaces: [ConversationDetails] = []
        for row in response.invitations
            where text.isEmpty || row.name.localizedCaseInsensitiveContains(text) {
            guard var details = try await directorySpace(
                row.groupID,
                generation: generation,
                client: apiClient
            ),
                details.membership == .invited else { continue }
            details.allowedActions = ["acceptInvitation", "declineInvitation"]
            spaces.append(details)
        }
        return SpaceDirectoryPage(spaces: spaces)
    }

    func createConversation(_ draft: ConversationDraft) async throws -> ConversationCreationResult {
        guard isConnected, let apiClient else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        await selfIdentification?.value
        try checkManagementGeneration(generation)
        guard let me = calendarPoll.me, draft.access == .restricted,
              draft.kind == .space || draft.kind == .groupDirectMessage else {
            throw ChatError.unsupported(capability: "conversationCreationSettings")
        }
        let people = Array(Set(draft.members)).filter { $0 != me }
        guard draft.kind != .space || !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.kind != .groupDirectMessage || people.count >= 2 else {
            throw ChatError.unknown("Enter a space name or choose at least two people for a group chat.")
        }
        let response = try await apiClient.call(.createGroup, ConversationManagementRequests.create(
            name: draft.name, description: draft.description, people: people.map(\.rawValue),
            space: draft.kind == .space, localID: UUID().uuidString
        ))
        try checkManagementGeneration(generation)
        let creatorFailed = ProtoFieldScan.fields(in: response.unknownFields.data).fields
            .contains { $0.number == 5 }
        guard response.hasGroup, !creatorFailed,
              var conversation = ManagementMapping.conversation(response.group) else {
            throw ChatError
                .unknown("Creation could not be confirmed. Reload your conversations before trying again.")
        }
        conversation.kind = draft.kind
        let accepted = Set(response.results.filter { !$0.hasReason || $0.reason == 0 }.compactMap {
            $0.hasMembership && $0.membership.id.groupID == response.group.groupID
                ? ChatKit.Member.ID($0.membership.id.memberID.userID.id) : nil
        })
        conversation.members = [me] + people.filter { accepted.contains($0) }
        emit(.conversationUpdated(conversation))
        return ConversationCreationResult(
            conversation: conversation,
            failedMembers: people.filter { !accepted.contains($0) }
        )
    }
}
