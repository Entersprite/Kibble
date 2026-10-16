import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
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
        let before = try await conversationDetails(id)
        guard before.allowedActions.contains(mutation.action) || mutation.isParticipantChange else {
            throw ChatError.unknown("You do not have permission to make this change.")
        }
        guard expectedRevision == nil || before.revision == expectedRevision else {
            throw ChatError.unknown("This conversation changed. Reload before saving.")
        }
        // Retain an uncertain result before suspension. Replaying an operation never resubmits a write.
        let uncertain = ConversationMutationResult(
            operationID: operationID,
            details: before,
            isConfirmed: false
        )
        managementOperations[key] = ManagementOperation(id: id, mutation: mutation, result: uncertain)
        let failed = try await applyManagementWrite(mutation, context: ManagementWriteContext(
            group: group, before: before, me: me, client: apiClient, generation: generation
        ))
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
        if context.mutation == .leave || context.mutation == .declineInvitation || context
            .mutation == .deleteSpace {
            after = before; after.membership = .unknown; after.allowedActions = []
        } else {
            after = try await conversationDetails(id)
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
        let group = context.group
        let client = context.client
        switch mutation {
        case let .identity(name, description, access):
            try await updateManagementIdentity(
                name: name,
                description: description,
                access: access,
                context: context
            )
        case let .addPeople(people):
            return try await addManagementPeople(people, group: group, client: client)
        case .join, .acceptInvitation, .requestJoin:
            return try await addManagementPeople(
                [context.me],
                group: group,
                join: mutation != .requestJoin,
                requestJoin: mutation == .requestJoin,
                client: client
            )
        case .leave:
            try await performConversationAction(.leave, in: context.before.conversation.id)
        case .declineInvitation:
            try await removeManagementPerson(context.me, group: group, client: client)
        case let .removePerson(person), let .rejectRequest(person), let .approveRequest(person), let .setRole(
            person,
            _
        ):
            return try await updateManagementParticipant(mutation, person: person, context: context)
        case .deleteSpace:
            guard context.before.conversation.kind == .space,
                  context.before.allowedActions.contains("deleteSpace") else {
                throw ChatError.unsupported(capability: "deleteSpace")
            }
            _ = try await client.call(.deleteGroupV2, ConversationManagementRequests.deleteSpace(group))
        case .unknown:
            throw ChatError.unsupported(capability: mutation.action)
        }
        return []
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

    private func updateManagementParticipant(
        _ mutation: ConversationMutation,
        person: ChatKit.Member.ID,
        context: ManagementWriteContext
    ) async throws
        -> [ChatKit.Member.ID] {
        let group = context.group
        let client = context.client
        let target = try await managementTarget(person, group: group, generation: context.generation)
        guard target.allowedActions.contains(mutation.action), person != context.me else {
            throw ChatError.unknown("This member cannot be changed with your current permissions.")
        }
        if case let .setRole(_, role) = mutation {
            guard target.allowedRoles.contains(role), let wire = ManagementMapping.role(role) else {
                throw ChatError.unsupported(capability: "conversationRole")
            }
            let response = try await client.call(
                .updateMembershipRole,
                ConversationManagementRequests.role(
                    wire,
                    user: person.rawValue,
                    group: group
                )
            )
            guard response.results.contains(where: {
                $0.hasMembership && $0.membership.id.groupID == group
                    && $0.membership.id.memberID.userID.id == person.rawValue
                    && $0.membership.membershipRole == wire && (!$0.hasStatus || $0.status == 0)
            }) else { throw unconfirmedManagement() }
        } else if case .approveRequest = mutation {
            return try await addManagementPeople([person], group: group, join: true, client: client)
        } else {
            try await removeManagementPerson(person, group: group, client: client)
        }
        return []
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
        guard let row = response.memberships.first(where: { $0.id.memberID.userID.id == person.rawValue }),
              let target = ManagementMapping.participant(row, group: group, me: me, people: [:], caps: caps)
        else {
            throw ChatError.unknown("This member is no longer available. Reload the people list.")
        }
        return target
    }

    func unconfirmedManagement() -> ChatError {
        .unknown("The service did not confirm this change. Reload before trying again.")
    }
}

struct ManagementOperation {
    var id: Conversation.ID
    var mutation: ConversationMutation
    var result: ConversationMutationResult
}

private extension ConversationMutation {
    var isParticipantChange: Bool {
        switch self {
        case .removePerson, .setRole, .approveRequest, .rejectRequest: true
        default: false
        }
    }
}

struct ManagementWriteContext {
    var group: GroupId
    var before: ConversationDetails
    var me: ChatKit.Member.ID
    var client: ProtoAPIClient
    var generation: Int
}

private struct ManagementCompletion {
    var key: String
    var mutation: ConversationMutation
    var operationID: String
    var generation: Int
}
