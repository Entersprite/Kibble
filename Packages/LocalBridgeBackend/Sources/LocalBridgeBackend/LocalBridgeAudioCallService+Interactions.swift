import ChatKit
import Foundation

extension LocalBridgeAudioCallService: CallInteractionService {
    public func inviteToCall(_ member: Member.ID, callID: UUID) async throws {
        let scope = callScope
        try checkCall(callID, scope: scope)
        guard operation == nil else { throw CancellationError() }
        try await trial.inviteNativeParticipant(member.rawValue, scope: scope)
        try checkCall(callID, scope: scope)
    }

    public func setHandRaised(_ raised: Bool, callID: UUID) async throws {
        let scope = callScope
        try checkCall(callID, scope: scope)
        guard operation == nil else { throw CancellationError() }
        try await trial.setNativeHandRaised(raised, scope: scope)
        try checkCall(callID, scope: scope)
    }
}

extension LocalBridgeAudioCallService: CallActivitiesService {
    public func performCallActivity(_ activity: CallActivity, callID: UUID) async throws {
        let scope = callScope
        try checkCall(callID, scope: scope)
        guard operation == nil else { throw CancellationError() }
        try await trial.performNativeActivity(activity, scope: scope)
        try checkCall(callID, scope: scope)
    }
}

extension LocalBridgeAudioCallService {
    func receiveActivities(_ activities: CallActivitiesState, url: URL?, id: UUID, scope: UUID) {
        guard callScope == scope, currentCallID == id, !isStopping else { return }
        var state = CallInteractionState(joinURL: url, canRaiseHand: true, canInvite: true)
        state.activities = activities
        continuation.yield(.interactionChanged(callID: id, state: state))
    }
}
