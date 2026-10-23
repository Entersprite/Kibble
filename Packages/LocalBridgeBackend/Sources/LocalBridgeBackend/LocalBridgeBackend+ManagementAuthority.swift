import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// A page containing another owner need not contain the viewer. Validate
    /// the viewer's own membership before exposing or dispatching that action.
    func managementViewerIsOwner(
        group: GroupId, me: ChatKit.Member.ID, rows: [Membership], generation: Int,
        resolveWhenAbsent: Bool = false
    ) async throws -> Bool {
        if let own = rows.first(where: {
            ManagementMapping.belongs($0, to: group) && $0.id.memberID.userID.id == me.rawValue
        }) {
            return own.membershipState == .memberJoined && ManagementMapping.role(in: own) == .owner
        }
        guard resolveWhenAbsent || rows.contains(where: {
            ManagementMapping.belongs($0, to: group) && ManagementMapping.role(in: $0) == .owner
        }) else { return false }
        guard let client = apiClient else { throw ChatError.notAuthenticated }
        let response = try await client.call(
            .getMembership, MembersRequests.getMembership(member: me.rawValue, group: group)
        )
        try checkManagementGeneration(generation)
        return response.memberships.contains {
            ManagementMapping.belongs($0, to: group) && $0.id.memberID.userID.id == me.rawValue
                && $0.membershipState == .memberJoined && ManagementMapping.role(in: $0) == .owner
        }
    }
}
