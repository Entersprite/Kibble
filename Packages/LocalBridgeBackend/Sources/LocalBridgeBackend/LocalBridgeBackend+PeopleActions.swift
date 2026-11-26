import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func hasOtherManagementOwner(
        group: GroupId,
        me: ChatKit.Member.ID,
        generation: Int
    ) async throws -> Bool {
        guard let client = apiClient else { throw ChatError.notAuthenticated }
        var token: String?
        var seen = Set<String>()
        var count = 0
        for _ in 0 ..< 10 {
            let response = try await client.call(
                .listMembers,
                MembersRequests.listMembers(group: group, pageToken: token)
            )
            try checkManagementGeneration(generation)
            guard response.memberships.allSatisfy({ ManagementMapping.belongs($0, to: group) }) else {
                throw ChatError.decoding("The service returned another conversation's members.")
            }
            count += response.memberships.count
            guard count <= 1024 else { throw ChatError.unsupported(capability: "ownerMembership") }
            if response.memberships.contains(where: {
                $0.id.memberID.userID.id != me.rawValue && !$0.id.memberID.userID.id.isEmpty
                    && $0.id.memberID.userID.type == .human && $0.membershipState == .memberJoined
                    && ManagementMapping.role(in: $0) == .owner
            }) {
                return true
            }
            guard !response.nextPageToken.isEmpty else { return false }
            guard seen.insert(response.nextPageToken).inserted else {
                throw ChatError.decoding("The owner list could not be completed.")
            }
            token = response.nextPageToken
        }
        throw ChatError.unsupported(capability: "ownerMembership")
    }

    func blockManagementPerson(
        _ person: ChatKit.Member.ID,
        blocked: Bool,
        context: ManagementWriteContext
    ) async throws {
        guard capabilities.canBlockConversations, context.before.membership == .joined,
              person != context.me else {
            throw ChatError.unsupported(capability: "blockPerson")
        }
        let response = try await context.client.call(
            .getMembership, MembersRequests.getMembership(member: person.rawValue, group: context.group)
        )
        try checkManagementGeneration(context.generation)
        guard response.memberships.contains(where: {
            ManagementMapping.belongs($0, to: context.group) && $0.id.memberID.userID.id == person.rawValue
                && $0.id.memberID.userID.type == .human && [.memberJoined, .memberInvited]
                .contains($0.membershipState)
        }) else { throw ChatError.unsupported(capability: "blockPerson") }
        var user = UserId(); user.id = person.rawValue
        var request = ConversationActionRequests.block(group: context.group, user: user)
        request.blocked = blocked
        let answer = try await context.client.call(.blockEntity, request)
        try checkManagementGeneration(context.generation)
        guard answer.hasUserRevision || answer.hasReadState else { throw unconfirmedManagement() }
    }
}
