import ChatKit
import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
    func prepareExisting(person: UUID) async throws -> PreparedMeetDMCall {
        await endNativeCall()
        prepared = nil
        generation += 1
        let currentGeneration = generation
        guard let target = targets[person], let context else { throw MeetDMCallTrialError.invalidPerson }
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let wiz = try await Bootstrap(transport: transport).run(
            cookies: currentCookies(for: context.stored), endpoints: endpoints
        )
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        guard wiz.isSignedIn else { throw MeetDMCallTrialError.signedOut }
        let chat = ProtoAPIClient(
            transport: transport, endpoints: endpoints, credentials: context.credentials,
            xsrfToken: wiz.xsrfToken
        )
        let reference = try await existingReference(target, chat: chat, generation: currentGeneration)
        let client = try await loadCallClient(context, generation: currentGeneration)
        try ensureGeneration(currentGeneration)
        let call = try await client.resolveExisting(code: reference.code)
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let current = try await existingReference(target, chat: chat, generation: currentGeneration)
        // A meeting code can survive a replacement conference. Compare the
        // full integration, including its conference and participant revision.
        guard current.data == reference.data else { throw MeetDMCallTrialError.callChanged }
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let ticket = UUID()
        prepared = Prepared(
            ticket: ticket, generation: currentGeneration, target: target,
            context: context, client: client, call: call, ownerReportedBrowserJoin: false,
            permitsInvitation: false
        )
        lines.append("Existing call reference resolved and revalidated; invitation disabled")
        return PreparedMeetDMCall(id: ticket, url: call.space.url)
    }
}

private extension MeetDMCallTrial {
    func existingReference(
        _ target: Target, chat: ProtoAPIClient, generation: Int
    ) async throws -> (code: String, data: CallSpaceIntegrationPayload) {
        var group = GroupId(); group.dmID.dmID = target.dmID
        let response = try await chat.call(.managementDetails, ConversationManagementRequests.details(group))
        try ensureGeneration(generation)
        guard response.hasGroup, response.group.groupID == group,
              response.hasMembershipState, response.membershipState == .memberJoined,
              let payload = CallAvailabilityMapping.payload(in: response.group) else {
            throw MeetDMCallTrialError.callChanged
        }
        let value = CallAvailabilityMapping.map(payload, in: target.conversationID, at: Date())
        guard value.status == .active, let reference = value.reference else {
            throw MeetDMCallTrialError.callChanged
        }
        return (reference, payload)
    }
}
