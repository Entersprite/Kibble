import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    private func validateManagementWrite(
        _ mutation: ConversationMutation, before: ConversationDetails, expectedRevision: String?
    ) throws {
        guard before.allowedActions.contains(mutation.action) || mutation.isParticipantChange else {
            recordManagementStage("preflightPermission", failure: "denied")
            throw ChatError.unknown("You do not have permission to make this change.")
        }
        guard expectedRevision == nil || before.revision == expectedRevision else {
            recordManagementStage("preflightRevision", failure: "changed")
            throw ChatError.unknown("This conversation changed. Reload before saving.")
        }
    }

    func mutateConversation(
        _ mutation: ConversationMutation,
        in id: Conversation.ID,
        operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: id),
              !operationID.isEmpty, let me = calendarPoll.me else { throw ChatError.notAuthenticated }
        let generation = directoryGeneration
        let key = "\(generation):\(operationID)"
        if let old = managementOperations[key] {
            guard old.id == id,
                  old.mutation == mutation
            else { throw ChatError.unknown("Operation identifier already used.") }
            return old.result
        }
        guard managementOperations.count < 200 else {
            throw ChatError.unknown("Reload the account before making more changes.")
        }
        managementOperations[key] = ManagementOperation(
            id: id,
            mutation: mutation,
            result: ConversationMutationResult(
                operationID: operationID,
                isConfirmed: false
            )
        )
        let before = try await managementStep("preflightDetails") {
            try await conversationDetails(id)
        }
        try validateManagementWrite(mutation, before: before, expectedRevision: expectedRevision)
        // Retain an uncertain result before suspension. Replaying an operation never resubmits a write.
        let uncertain = ConversationMutationResult(
            operationID: operationID,
            details: before,
            isConfirmed: false
        )
        managementOperations[key] = ManagementOperation(id: id, mutation: mutation, result: uncertain)
        let failed = try await managementStep("applyWrite") {
            try await applyManagementWrite(mutation, context: ManagementWriteContext(
                group: group, before: before, me: me, client: apiClient, generation: generation
            ))
        }
        try checkManagementGeneration(generation)
        return try await finishManagementWrite(
            id,
            before: before,
            failed: failed,
            context: ManagementCompletion(
                key: key,
                mutation: mutation,
                operationID: operationID,
                generation: generation
            )
        )
    }
}

extension LocalBridgeBackend {
    private func finishManagementWrite(
        _ id: Conversation.ID,
        before: ConversationDetails,
        failed: [ChatKit.Member.ID],
        context: ManagementCompletion
    ) async throws
        -> ConversationMutationResult {
        let generation = context.generation
        let key = context.key
        let mutation = context.mutation
        let operationID = context.operationID
        var after: ConversationDetails
        if [.leave, .declineInvitation, .deleteSpace, .block].contains(context.mutation) {
            after = before; after.membership = .unknown; after.allowedActions = []
        } else {
            after = try await managementStep("completionDetails") {
                try await conversationDetails(id)
            }
        }
        try checkManagementGeneration(generation)
        let result = ConversationMutationResult(
            operationID: operationID,
            details: after,
            failedMembers: failed
        )
        managementOperations[key] = ManagementOperation(id: id, mutation: mutation, result: result)
        if after.membership == .joined {
            emit(.conversationUpdated(after.conversation))
        } else if before.membership == .joined {
            emit(.conversationRemoved(
                conversationID: id,
                historyBefore: nil
            ))
        }
        return result
    }

    func applyManagementWrite(_ mutation: ConversationMutation, context: ManagementWriteContext) async throws
        -> [ChatKit.Member.ID] {
        if try await applyManagementSettings(mutation, context: context) {
            return []
        }
        if try await applyManagementIntegrations(mutation, context: context) {
            return []
        }
        let group = context.group
        let client = context.client
        switch mutation {
        case let .setPersonBlocked(person, blocked):
            try await blockManagementPerson(person, blocked: blocked, context: context)
        case let .addPeople(people):
            return try await addManagementPeople(people, group: group, client: client)
        case .join, .acceptInvitation, .requestJoin:
            return try await joinManagementConversation(mutation, context: context)
        case .leave, .declineInvitation, .block:
            try await leaveManagementConversation(mutation, context: context)
        case let .removePerson(person), let .rejectRequest(person), let .approveRequest(person), let .setRole(
            person,
            _
        ):
            return try await updateManagementParticipant(mutation, person: person, context: context)
        case .deleteSpace:
            try await deleteManagementSpace(context)
        default:
            throw ChatError.unsupported(capability: mutation.action)
        }
        return []
    }

    private func leaveManagementConversation(
        _ mutation: ConversationMutation, context: ManagementWriteContext
    ) async throws {
        switch mutation {
        case .leave:
            try await performConversationAction(.leave, in: context.before.conversation.id)
        case .declineInvitation:
            try await removeManagementPerson(context.me, group: context.group, client: context.client)
        case .block:
            try await blockManagementSpace(context.before, group: context.group, client: context.client)
        default: throw ChatError.unsupported(capability: mutation.action)
        }
    }

    private func joinManagementConversation(
        _ mutation: ConversationMutation, context: ManagementWriteContext
    ) async throws -> [ChatKit.Member.ID] {
        try await addManagementPeople(
            [context.me], group: context.group, join: mutation != .requestJoin,
            requestJoin: mutation == .requestJoin, client: context.client
        )
    }

    private func applyManagementSettings(
        _ mutation: ConversationMutation,
        context: ManagementWriteContext
    ) async throws -> Bool {
        switch mutation {
        case let .convertToSpace(name, emoji, acknowledged):
            try await convertManagementChat(
                name: name,
                emoji: emoji,
                acknowledged: acknowledged,
                context: context
            )
        case let .settings(patch):
            try await updateSpaceSettings(patch, context: context)
        case let .emoji(value):
            try await updateConversationEmoji(value, context: context)
        case let .identity(name, description, access):
            try await updateManagementIdentity(
                name: name,
                description: description,
                access: access,
                context: context
            )
        case let .details(patch):
            try await updateManagementDetails(
                name: patch.name,
                description: patch.description,
                guidelines: patch.guidelines,
                emoji: patch.emoji,
                context: context
            )
        case let .guidelines(value):
            try await updateManagementDetails(description: nil, guidelines: value, context: context)
        default: return false
        }
        return true
    }

    private func deleteManagementSpace(_ context: ManagementWriteContext) async throws {
        guard context.before.conversation.kind == .space,
              context.before.allowedActions.contains("deleteSpace") else {
            throw ChatError.unsupported(capability: "deleteSpace")
        }
        _ = try await context.client.call(
            .deleteGroupV2, ConversationManagementRequests.deleteSpace(context.group)
        )
    }

    private func updateManagementIdentity(
        name: String?,
        description: String?,
        access: ConversationAccess?,
        context: ManagementWriteContext
    ) async throws {
        let group = context.group
        let client = context.client
        guard access == nil,
              name == nil || context.before.allowedActions.contains("rename"),
              description == nil || context.before.allowedActions.contains("description") else {
            throw ChatError.unsupported(capability: "identityFields")
        }
        guard name == nil || (name?.utf16.count ?? 0) <= 128,
              name == nil || context.before.conversation.kind != .space
              || !(name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw ChatError.unknown("Enter a space name of up to 128 characters.")
        }
        if description != nil {
            try await updateManagementDetails(
                name: name, description: description, guidelines: nil, context: context
            )
            return
        }
        let response = try await client.call(
            .updateGroup,
            ConversationManagementRequests.identity(
                group,
                name: name,
                description: description
            )
        )
        guard response.hasGroup, response.group.groupID == group,
              name == nil || response.group.name == name,
              description == nil || response.group.groupDetails.description_p == description
        else { throw unconfirmedManagement() }
    }

    func addManagementPeople(
        _ people: [ChatKit.Member.ID],
        group: GroupId,
        join: Bool = false,
        requestJoin: Bool = false,
        client: ProtoAPIClient
    ) async throws -> [ChatKit.Member.ID] {
        guard !people.isEmpty, people.allSatisfy({ !$0.rawValue.isEmpty }) else {
            throw ChatError.unknown("Choose at least one person.")
        }
        let response = try await client.call(
            .createMembership,
            ConversationManagementRequests.add(
                people.map(\.rawValue),
                group: group,
                join: join,
                requestJoin: requestJoin
            )
        )
        guard !response.results.isEmpty else { throw unconfirmedManagement() }
        let accepted = Set(response.results.filter { !$0.hasReason || $0.reason == 0 }
            .compactMap { row -> ChatKit.Member.ID? in
                guard row.hasMembership, row.membership.id.groupID == group else { return nil }
                return ChatKit.Member.ID(row.membership.id.memberID.userID.id)
            })
        return people.filter { !accepted.contains($0) }
    }

    func removeManagementPerson(
        _ person: ChatKit.Member.ID,
        group: GroupId,
        client: ProtoAPIClient
    ) async throws {
        let member = ConversationManagementRequests.membershipID(group: group, user: person.rawValue).memberID
        let response = try await client.call(
            .removeMemberships,
            ConversationActionRequests.leave(group: group, member: member)
        )
        guard response.results
            .contains(where: { $0.memberID == member && (!$0.hasReason || $0.reason == 0) }) else {
            throw unconfirmedManagement()
        }
    }

    func managementTarget(
        _ person: ChatKit.Member.ID,
        group: GroupId,
        generation: Int
    ) async throws -> ConversationParticipant {
        guard let client = apiClient, let me = calendarPoll.me else { throw ChatError.notAuthenticated }
        let response = try await client.call(
            .getMembership,
            MembersRequests.getMembership(
                member: person.rawValue,
                group: group
            )
        )
        try checkManagementGeneration(generation)
        let caps = try await managementPermissions(group, user: me.rawValue, generation: generation)
        let viewerIsOwner = try await managementViewerIsOwner(
            group: group, me: me, rows: response.memberships, generation: generation,
            resolveWhenAbsent: ManagementMapping.grants(
                caps,
                2
            )
        )
        let selfRoleChange = person == me && viewerIsOwner
            ? try await hasOtherManagementOwner(group: group, me: me, generation: generation) : false
        guard let row = response.memberships.first(where: { $0.id.memberID.userID.id == person.rawValue }),
              let target = ManagementMapping.participant(
                  row, group: group, me: me, people: [:], caps: caps, viewerIsOwner: viewerIsOwner,
                  selfRoleChange: selfRoleChange
              )
        else {
            throw ChatError.unknown("This member is no longer available. Reload the people list.")
        }
        return target
    }

    /// `block_entity` for the space itself, the request the conversation
    /// menu's Block sends for a joined space. A space the account has not
    /// joined is not in the world, so this works from its group alone. That
    /// Google accepts it and confirms it this way for an invited space is
    /// `[Verify]`.
    private func blockManagementSpace(
        _ before: ConversationDetails,
        group: GroupId,
        client: ProtoAPIClient
    ) async throws {
        guard before.conversation.kind == .space, before.allowedActions.contains("block") else {
            throw ChatError.unsupported(capability: "block")
        }
        let response = try await client.call(
            .blockEntity,
            ConversationActionRequests.block(group: group, user: nil)
        )
        guard response.hasUserRevision || response.hasReadState else { throw unconfirmedManagement() }
    }

    func unconfirmedManagement() -> ChatError {
        .unknown("The service did not confirm this change. Reload before trying again.")
    }
}

private extension ConversationMutation {
    var isParticipantChange: Bool {
        switch self {
        case .removePerson, .setRole, .approveRequest, .rejectRequest, .setPersonBlocked: true
        default: false
        }
    }
}

private struct ManagementCompletion {
    var key: String
    var mutation: ConversationMutation
    var operationID: String
    var generation: Int
}
