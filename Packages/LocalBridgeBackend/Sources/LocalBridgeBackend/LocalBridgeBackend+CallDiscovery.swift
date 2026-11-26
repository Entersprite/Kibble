import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend: CallDiscoveryBackend {
    public func callAvailability(in id: Conversation.ID) async throws -> ConversationCallAvailability {
        guard isConnected, let apiClient, let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.notAuthenticated
        }
        let generation = directoryGeneration
        let first = try await currentCall(group, using: apiClient, generation: generation)
        let initial = CallAvailabilityMapping.map(first, in: id, at: Date())
        guard initial.status == .active else { return initial }
        // The roster adds a count. The fresh group read owns whether Join is available.
        let roster = try? await currentCallParticipants(group, using: apiClient, generation: generation)
        try checkManagementGeneration(generation)
        // The roster read can straddle a replacement call or an end.
        let last = try await currentCall(group, using: apiClient, generation: generation)
        return CallAvailabilityMapping.map(last, in: id, at: Date(), roster: first == last ? roster : nil)
    }

    private func currentCall(
        _ group: GroupId, using client: ProtoAPIClient, generation: Int
    ) async throws -> CallSpaceIntegrationPayload? {
        let response = try await client.call(
            .managementDetails, ConversationManagementRequests.details(group)
        )
        try checkManagementGeneration(generation)
        guard response.hasGroup, response.group.groupID == group,
              response.hasMembershipState, response.membershipState == .memberJoined else {
            throw ChatError.unknown("The call is unavailable in this conversation.")
        }
        return CallAvailabilityMapping.payload(in: response.group)
    }

    private func currentCallParticipants(
        _ group: GroupId, using client: ProtoAPIClient, generation: Int
    ) async throws -> CallDiscoveryRequests.Participants {
        let response = try await client.call(.getCallData, CallDiscoveryRequests.participants(in: group))
        try checkManagementGeneration(generation)
        return try CallDiscoveryRequests.participants(from: response)
    }
}
