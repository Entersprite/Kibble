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
        var step = "listMembers"
        let response: ListMembersResponse
        // A member who is not a person (an app, a group) has no user id and
        // nothing a People row can show; it is left out rather than hiding
        // everyone else. A row naming another conversation still refuses
        // the page, because then the whole answer is in doubt.
        let people: [Membership]
        let rows: [ConversationParticipant]
        do {
            let token = try ManagementCursor.decode(cursor, key: "people:\(generation):\(id.rawValue)")
            response = try await apiClient.call(
                .listMembers,
                MembersRequests.listMembers(group: group, pageToken: token)
            )
            try checkManagementGeneration(generation)
            people = response.memberships.filter { !$0.id.memberID.userID.id.isEmpty }
            step = "getMembers"
            let byID = try await participantProfiles(
                people.map { ChatKit.Member.ID($0.id.memberID.userID.id) },
                using: apiClient,
                generation: generation
            )
            step = "permissions"
            let caps = try await managementPermissions(group, user: me.rawValue, generation: generation)
            let viewerIsOwner = people.contains {
                $0.id.memberID.userID.id == me.rawValue && $0.membershipRole == .roleOwner
            }
            rows = people.compactMap {
                ManagementMapping.participant(
                    $0, group: group, me: me, people: byID, caps: caps, viewerIsOwner: viewerIsOwner
                )
            }
            recordPeoplePage(response, people: people, mapped: rows.count, group: group)
        } catch {
            diagnostics.record(.peopleListFailed(step: step, failure: ManagementFailureKind.of(error)))
            throw error
        }
        guard rows.count == people.count else {
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

    /// Not announced as `membersResolved`: the service fences a people query
    /// against such events and would ask it again, forever. The page carries
    /// each profile, and the service records its media.
    private func participantProfiles(
        _ ids: [ChatKit.Member.ID],
        using apiClient: ProtoAPIClient,
        generation: Int
    ) async throws -> [ChatKit.Member.ID: ChatKit.Member] {
        let profiles = ids.isEmpty ? GetMembersResponse() : try await apiClient.call(
            .getMembers,
            Self.getMembersRequest(ids)
        )
        try checkManagementGeneration(generation)
        let members = MemberMapping.map(profiles).members
        remember(emailsOf: members)
        return Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        let matched = response.capabilities.first { $0.id == id }
        recordPermissions(response, matched: matched)
        return matched ?? GroupScopedCapabilities()
    }

    /// Enum numbers only: which explicit permission fields Google sent, so the
    /// unconfirmed meaning of each (findings §69.4) can be measured.
    private func recordPermissions(
        _ response: GetGroupScopedCapabilitiesResponse,
        matched: GroupScopedCapabilities?
    ) {
        guard let shown = matched ?? response.capabilities.first else {
            diagnostics.record(.managementPermissions(rows: 0, matched: false, legacy: [], explicit: []))
            return
        }
        let data = shown.permissions.unknownFields.data
        let numbers = Set(ProtoFieldScan.fields(in: data).fields.filter { $0.wireType == 0 }.map(\.number))
        let explicit = numbers.sorted().map { number in
            "\(number)=\(ProtoFieldScan.varintValues(ofField: number, in: data).last.map(String.init) ?? "?")"
        }
        diagnostics.record(.managementPermissions(
            rows: response.capabilities.count,
            matched: matched != nil,
            legacy: shown.capabilities + shown.permissions.capabilities,
            explicit: explicit
        ))
    }

    private func recordPeoplePage(
        _ response: ListMembersResponse,
        people: [Membership],
        mapped: Int,
        group: GroupId
    ) {
        diagnostics.record(.peopleRoles(people.map { row in
            ProtoFieldScan.varintValues(ofField: 5, in: row.unknownFields.data).last.map { Int($0) }
                ?? row.membershipRole.rawValue
        }))
        diagnostics.record(.peopleListRows(
            total: response.memberships.count,
            mapped: mapped,
            withoutUser: response.memberships.count - people.count,
            outsideGroup: response.memberships.count { !ManagementMapping.belongs($0, to: group) }
        ))
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
