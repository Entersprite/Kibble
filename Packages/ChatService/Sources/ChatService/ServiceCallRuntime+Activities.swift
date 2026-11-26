import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func performActivity(
        _ request: PerformCallActivity,
        session: ClientSessionID
    ) async throws -> ServiceCallState {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        guard reserved == request.callID, state.currentCallID == request.callID,
              owner == session, state.currentPhase == .connected else { throw ServiceFailure.notAuthorized }
        let activity = request.activity
        guard activity.action.utf8.count <= 64, activity.text.utf8.count <= 16000,
              !activity.text.contains("\0"),
              activity.options.count <= 10,
              activity.options.allSatisfy({ $0.utf8.count <= 1000 && !$0.contains("\0") }),
              activity.participantIDs.count <= 256,
              Set(activity.participantIDs).count == activity.participantIDs.count,
              activity.selections.count <= 10,
              activity.selections.allSatisfy({ (0 ..< 10).contains($0) }) else {
            throw ServiceFailure.invalidRequest
        }
        guard let activities = source as? any CallActivitiesService,
              let current = state.interaction?.activities, current.availableActions.contains(activity.action),
              current.acceptsRecordingCaptionChoice(activity) else {
            throw ServiceFailure.unsupportedOperation
        }
        guard !controlling else { throw ServiceFailure.deviceBusy }
        guard !usedActivityRequests.contains(request.requestID)
        else { throw ServiceFailure.operationConflict }
        guard usedActivityRequests.count < 4096 else { throw ServiceFailure.overloaded }
        usedActivityRequests.insert(request.requestID)
        controlling = true
        defer { controlling = false }
        try await activities.performCallActivity(activity, callID: request.callID)
        try checkActive()
        return state
    }
}
