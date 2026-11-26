import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func inviteParticipant(
        _ request: InviteCallParticipant,
        session: ClientSessionID
    ) async throws -> ServiceCallState {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        guard reserved == request.callID, state.currentCallID == request.callID,
              owner == session, state.currentPhase == .connected else { throw ServiceFailure.notAuthorized }
        guard state.interaction?.canInvite == true,
              let interactions = source as? any CallInteractionService
        else { throw ServiceFailure.unsupportedOperation }
        guard !request.memberID.rawValue.isEmpty, request.memberID.rawValue.utf8.count <= 128 else {
            throw ServiceFailure.invalidRequest
        }
        guard !controlling else { throw ServiceFailure.deviceBusy }
        controlling = true
        defer { controlling = false }
        guard !sentInvitations.contains(request.invitationID) else { throw ServiceFailure.operationConflict }
        guard sentInvitations.count < 1024 else { throw ServiceFailure.overloaded }
        sentInvitations.insert(request.invitationID)
        try await interactions.inviteToCall(request.memberID, callID: request.callID)
        try checkActive()
        return state
    }

    func controlInteraction(
        _ request: ControlCallInteraction,
        session: ClientSessionID
    ) async throws -> ServiceCallState {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        guard reserved == request.callID, state.currentCallID == request.callID,
              owner == session, state.currentPhase == .connected else { throw ServiceFailure.notAuthorized }
        guard state.interaction?.canRaiseHand == true,
              let interactions = source as? any CallInteractionService
        else { throw ServiceFailure.unsupportedOperation }
        guard !controlling else { throw ServiceFailure.deviceBusy }
        controlling = true
        defer { controlling = false }
        try await interactions.setHandRaised(request.raised, callID: request.callID)
        try checkActive()
        return state
    }
}
