import ChatKit
import Foundation
import GChatBridgeCore

public extension MeetDMCallTrial {
    /// Quiet huddle setup. A group target has no callee or invitation path.
    func prepareConversation(in id: Conversation.ID, joining: Bool) async throws -> PreparedMeetDMCall {
        await endNativeCall()
        prepared = nil
        generation += 1
        let currentGeneration = generation
        guard let context, let group = ChannelEventMapping.groupID(for: id) else {
            throw MeetDMCallTrialError.invalidPerson
        }
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let chat = try await conversationCallClient(context, generation: currentGeneration)
        let before = try await conversationCallGroup(group, chat: chat, generation: currentGeneration)
        let payload = CallAvailabilityMapping.payload(in: before)
        let availability = CallAvailabilityMapping.map(payload, in: id, at: Date())
        let client = try await loadCallClient(context, generation: currentGeneration)
        try ensureGeneration(currentGeneration)
        let call: MeetResolvedCall
        if availability.status == .active, let code = availability.reference {
            call = try await client.resolveExisting(code: code)
        } else {
            guard !joining, availability.status == .inactive || before.spaceIntegrationPayloads.allSatisfy({
                $0.type != 5 && !$0.hasCallIntegrationPayload
            }) else { throw MeetDMCallTrialError.callChanged }
            let raw: String
            switch group.id {
            case let .spaceID(value): raw = value.spaceID
            case let .dmID(value): raw = value.dmID
            case nil: throw MeetDMCallTrialError.invalidPerson
            }
            call = try await client.resolveConversation(groupID: raw)
        }
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let after = try await conversationCallGroup(group, chat: chat, generation: currentGeneration)
        try validateConversationReference(before: before, after: after, call: call, in: id)
        try await ensureCurrent(context.stored)
        try ensureGeneration(currentGeneration)
        let ticket = UUID()
        prepared = Prepared(
            ticket: ticket, generation: currentGeneration, target: nil,
            context: context, client: client, call: call, ownerReportedBrowserJoin: false,
            permitsInvitation: false, isConversationCall: true
        )
        return PreparedMeetDMCall(id: ticket, url: call.space.url)
    }
}

private extension MeetDMCallTrial {
    func conversationCallClient(_ context: Context, generation: Int) async throws -> ProtoAPIClient {
        let wiz = try await Bootstrap(transport: transport).run(
            cookies: currentCookies(for: context.stored), endpoints: endpoints
        )
        try await ensureCurrent(context.stored)
        try ensureGeneration(generation)
        guard wiz.isSignedIn else { throw MeetDMCallTrialError.signedOut }
        return ProtoAPIClient(
            transport: transport, endpoints: endpoints, credentials: context.credentials,
            xsrfToken: wiz.xsrfToken
        )
    }

    func validateConversationReference(
        before: Group,
        after: Group,
        call: MeetResolvedCall,
        in id: Conversation.ID
    ) throws {
        let payload = CallAvailabilityMapping.payload(in: before)
        let availability = CallAvailabilityMapping.map(payload, in: id, at: Date())
        let current = CallAvailabilityMapping.payload(in: after)
        if availability.status == .active {
            guard current == payload else { throw MeetDMCallTrialError.callChanged }
        } else if let current {
            let value = CallAvailabilityMapping.map(current, in: id, at: Date())
            // Resolve may itself publish the new huddle. Never join a concurrent
            // replacement, and never interpret an unknown state as permission.
            guard value.status == .inactive || (value.status == .active && value.reference == call.space.code)
            else { throw MeetDMCallTrialError.callChanged }
        } else {
            guard after.spaceIntegrationPayloads.allSatisfy({ $0.type != 5 && !$0.hasCallIntegrationPayload })
            else { throw MeetDMCallTrialError.callChanged }
        }
    }

    func conversationCallGroup(
        _ group: GroupId,
        chat: ProtoAPIClient,
        generation: Int
    ) async throws -> Group {
        let response = try await chat.call(.managementDetails, ConversationManagementRequests.details(group))
        try ensureGeneration(generation)
        guard response.hasGroup, response.group.groupID == group,
              response.hasMembershipState, response.membershipState == .memberJoined,
              [Conversation.Kind.space, .groupDirectMessage].contains(
                  ManagementMapping.conversation(response.group)?.kind ?? .unknown("unknown")
              ) else { throw MeetDMCallTrialError.callChanged }
        return response.group
    }
}
