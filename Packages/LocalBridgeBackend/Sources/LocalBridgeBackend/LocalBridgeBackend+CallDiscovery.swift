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
        let roster = try await currentCallParticipants(group, generation: generation)
        // A participant request and group refresh can straddle a replacement
        // call or an end. Never attach the old roster to the newer meeting.
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
        _ group: GroupId, generation: Int
    ) async throws -> CallDiscoveryRequests.Participants {
        guard let context = bootstrapWiz.flatMap({ BatchExecuteContext($0) }) else {
            throw ChatError.unknown("The session lacks the context required to read call participants.")
        }
        searchRequestID += 100_000
        let call = try CallDiscoveryRequests.participants(in: group)
        let request = BatchExecute.request(
            call, context: context, requestID: searchRequestID, endpoints: endpoints,
            sendsExtensionHeader: false
        )
        let response = try await PunctualClient(transport: transport, credentials: credentials).send(request)
        try checkManagementGeneration(generation)
        guard response.status == 200 else {
            throw ChatError.server(status: response.status, message: "Reading call participants failed.")
        }
        let answers = try BatchExecute.answers(in: response.body)
            .filter { $0.rpc == CallDiscoveryRequests.rpc }
        guard answers.count == 1, let answer = answers.first,
              answer.errorCode == nil || answer.errorCode == 0, let payload = answer.payload else {
            throw ChatError.decoding("The service did not return call participants.")
        }
        return try CallDiscoveryRequests.participants(from: payload)
    }
}
