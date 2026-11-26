import ChatKit
import GChatBridgeCore

extension LocalBridgeBackend {
    func updateManagementParticipant(
        _ mutation: ConversationMutation,
        person: ChatKit.Member.ID,
        context: ManagementWriteContext
    ) async throws
        -> [ChatKit.Member.ID] {
        let group = context.group
        let client = context.client
        let target = try await managementTarget(person, group: group, generation: context.generation)
        guard target.allowedActions.contains(mutation.action) else {
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
            try checkManagementGeneration(context.generation)
            let echoed = response.results.contains {
                $0.hasMembership && $0.membership.id.groupID == group
                    && $0.membership.id.memberID.userID.id == person.rawValue
                    && $0.membership.membershipRole == wire && (!$0.hasStatus || $0.status == 0)
            }
            if !echoed {
                let current = try await client.call(
                    .getMembership, MembersRequests.getMembership(member: person.rawValue, group: group)
                )
                try checkManagementGeneration(context.generation)
                guard current.memberships.contains(where: {
                    $0.id.groupID == group && $0.id.memberID.userID.id == person.rawValue
                        && $0.membershipRole == wire
                }) else { throw unconfirmedManagement() }
            }
        } else if case .approveRequest = mutation {
            return try await addManagementPeople([person], group: group, join: true, client: client)
        } else {
            try await removeManagementPerson(person, group: group, client: client)
        }
        return []
    }
}
