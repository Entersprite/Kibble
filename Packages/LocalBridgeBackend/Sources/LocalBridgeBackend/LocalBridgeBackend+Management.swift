import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func conversationDetails(_ id: Conversation.ID) async throws -> ConversationDetails {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.notAuthenticated
        }
        let generation = directoryGeneration
        await selfIdentification?.value
        try checkManagementGeneration(generation)
        guard let me = calendarPoll.me else { throw ChatError.notAuthenticated }
        let response = try await apiClient.call(
            .managementDetails,
            ConversationManagementRequests.details(group)
        )
        try checkManagementGeneration(generation)
        guard response.hasGroup, response.group.groupID == group,
              var conversation = ManagementMapping.conversation(
                  response.group,
                  fallback: conversationDetails[id].flatMap(WorldMapping.conversation)
              ) else {
            throw ChatError.decoding("The service did not return this conversation.")
        }
        ManagementMapping.adoptMembers(response, into: &conversation)
        let state = ManagementMapping.state(
            response.membershipState,
            unknown: response.unknownFields.data,
            field: 6
        )
        let capabilities = state == .joined
            ? try await managementPermissions(group, user: me.rawValue, generation: generation)
            : GroupScopedCapabilities()
        var actions = ManagementMapping.actions(capabilities, joined: state == .joined)
        if case .spaceID = group.id, state == .joined, conversation.kind == .space,
           ManagementMapping.canDeleteSpace(capabilities) {
            actions.insert("deleteSpace")
        }
        if state == .joined,
           ConversationAction.leave.isAvailable(for: conversation.kind) {
            actions.insert("leave")
        }
        actions.formUnion(Self.invitationActions(state: state, kind: conversation.kind))
        if discoverableManagementSpaces.contains(id), state != .joined, state != .invited,
           state != .requested {
            actions.insert("requestJoin")
        }
        return ManagementMapping.details(
            response,
            conversation: conversation,
            membership: state,
            actions: actions
        )
    }

    func participants(
        in id: Conversation.ID,
        after cursor: String?
    ) async throws -> ConversationParticipantPage {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: id),
              let me = calendarPoll.me else {
            throw ChatError.notAuthenticated
        }
        let generation = directoryGeneration
        let token = try ManagementCursor.decode(cursor, key: "people:\(generation):\(id.rawValue)")
        let response = try await apiClient.call(
            .listMembers,
            MembersRequests.listMembers(group: group, pageToken: token)
        )
        try checkManagementGeneration(generation)
        let ids = response.memberships.compactMap { row -> ChatKit.Member.ID? in
            let value = row.id.memberID.userID.id
            return value.isEmpty ? nil : ChatKit.Member.ID(value)
        }
        let profiles = ids.isEmpty ? GetMembersResponse() : try await apiClient.call(
            .getMembers,
            Self.getMembersRequest(ids)
        )
        try checkManagementGeneration(generation)
        let people = MemberMapping.map(profiles).members
        remember(emailsOf: people)
        emit(.membersResolved(people))
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let caps = try await managementPermissions(group, user: me.rawValue, generation: generation)
        let rows = response.memberships.compactMap {
            ManagementMapping.participant($0, group: group, me: me, people: byID, caps: caps)
        }
        guard rows.count == response.memberships.count else {
            throw ChatError.decoding("Some membership records could not be read. Reload the people list.")
        }
        return ConversationParticipantPage(
            participants: rows,
            nextCursor: ManagementCursor.encode(
                response.nextPageToken,
                key: "people:\(generation):\(id.rawValue)"
            )
        )
    }
}

extension LocalBridgeBackend {
    private static func invitationActions(state: ParticipantState, kind: Conversation.Kind) -> Set<String> {
        guard state == .invited else { return [] }
        var actions: Set = ["acceptInvitation", "declineInvitation"]
        if kind == .space {
            actions.insert("block")
        }
        return actions
    }

    func checkManagementGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isConnected, directoryGeneration == generation else { throw CancellationError() }
    }

    func managementPermissions(
        _ group: GroupId,
        user: String,
        generation: Int
    ) async throws -> GroupScopedCapabilities {
        guard let apiClient else { throw ChatError.notAuthenticated }
        let id = ConversationManagementRequests.membershipID(group: group, user: user)
        let response = try await apiClient.call(
            .managementPermissions,
            ConversationManagementRequests.permissions(id)
        )
        try checkManagementGeneration(generation)
        return response.capabilities.first { $0.id == id } ?? GroupScopedCapabilities()
    }
}

/// Opaque client cursor binds the provider token to its account-owned query.
struct ManagementCursor: Codable {
    var key: String
    var token: String
    static func encode(_ token: String, key: String) -> String? {
        guard !token.isEmpty else { return nil }
        return try? JSONEncoder().encode(Self(key: key, token: token)).base64EncodedString()
    }

    static func decode(_ value: String?, key: String) throws -> String? {
        guard let value else { return nil }
        guard let data = Data(base64Encoded: value), let cursor = try? JSONDecoder().decode(
            Self.self,
            from: data
        ),
            cursor.key == key else { throw ChatError.decoding("This page belongs to a different search.") }
        return cursor.token
    }
}
