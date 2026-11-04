import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func joinMeeting(_ request: JoinMeetingCall, session: ClientSessionID) async throws -> ServiceCallState {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        guard request.url.absoluteString.utf8.count <= 2048,
              request.url.scheme == "https", request.url.user == nil, request.url.password == nil else {
            throw ServiceFailure(code: "invalidRequest", details: .object([
                "callStage": .string("meetingLinkEnvelope")
            ]))
        }
        guard !controlling, reserved == nil, state.currentPhase?.isTerminal != false,
              !recoveryPaused else { throw ServiceFailure.deviceBusy }
        guard state.supportsMeetingLinks == true,
              let links = source as? any MeetingLinkAudioCallService else {
            throw ServiceFailure.unsupportedOperation
        }
        guard !used.contains(request.callID) else { throw ServiceFailure.operationConflict }
        guard used.count < 1024 else { throw ServiceFailure.overloaded }
        controlling = true
        defer { controlling = false }
        let url = try await validatedMeetingLink(request.url, using: links)
        try checkActive()
        try await reserve(request.callID, session: session)
        guard state.currentPhase?.isTerminal != false else {
            await releaseReservation()
            throw ServiceFailure.deviceBusy
        }
        used.insert(request.callID)
        state.participants = nil
        state.interaction = nil
        state.call = nil
        state.conversationCall = nil
        state.meetingCall = .init(
            id: request.callID,
            target: .init(meetingURL: url, displayName: "Meeting"), phase: .connecting
        )
        publish()
        do {
            try await links.joinMeeting(at: url, callID: request.callID)
            try checkActive()
        } catch {
            try? await source.hangUp(callID: request.callID)
            if state.meetingCall?.id == request.callID, state.currentPhase?.isTerminal != true {
                state.meetingCall?.phase = .failed
                state.meetingCall?.failureMessage = "The meeting could not be joined."
                await releaseReservation()
                publish()
            }
            throw error
        }
        return state
    }

    private func validatedMeetingLink(
        _ url: URL,
        using links: any MeetingLinkAudioCallService
    ) async throws -> URL {
        do {
            return try await links.normalizedMeetingLink(url)
        } catch {
            try checkActive()
            throw ServiceFailure(code: "invalidRequest", details: .object([
                "callStage": .string("meetingLinkNormalization")
            ]))
        }
    }
}
