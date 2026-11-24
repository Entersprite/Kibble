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
    func receiveActivities(
        _ activities: CallActivitiesState, interaction: CallInteractionState, id: UUID, scope: UUID
    ) {
        guard callScope == scope, currentCallID == id, !isStopping else { return }
        var state = interaction
        state.activities = activities
        continuation.yield(.interactionChanged(callID: id, state: state))
        let forced = activities.moderatorMute.map { $0 != lastModeratorMute } ?? false
        if forced {
            lastModeratorMute = activities.moderatorMute
            media?.setMuted(true)
            muteSequence += 1
        }
        if forced || activities.microphoneRestricted == true {
            publishForcedMute(sequenceAdvanced: forced)
        }
    }

    private func publishForcedMute(sequenceAdvanced: Bool) {
        if var current = conversationSnapshot, !current.phase.isTerminal, !current.isMuted {
            if !sequenceAdvanced {
                muteSequence += 1
            }
            current.isMuted = true
            publishConversation(current)
        } else if var current = snapshot, !current.phase.isTerminal, !current.isMuted {
            if !sequenceAdvanced {
                muteSequence += 1
            }
            current.isMuted = true
            snapshot = current
            continuation.yield(.snapshot(current))
        }
    }
}
