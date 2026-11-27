import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func createMeetingLink(_ request: CreateMeetingLink) async throws -> URL {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        guard state.supportsMeetingLinkCreation == true,
              let links = source as? any MeetingLinkAudioCallService else {
            throw ServiceFailure.unsupportedOperation
        }
        guard !usedMeetingLinkRequests.contains(request.requestID)
        else { throw ServiceFailure.operationConflict }
        guard usedMeetingLinkRequests.count < 1024 else { throw ServiceFailure.overloaded }
        guard !creatingMeetingLink, !recoveryPaused else { throw ServiceFailure.deviceBusy }
        usedMeetingLinkRequests.insert(request.requestID)
        creatingMeetingLink = true
        defer { creatingMeetingLink = false }
        let url = try await links.createMeetingLink()
        try checkActive()
        return url
    }

    func previewMeetingLink(_ request: PreviewMeetingLink) async throws -> String? {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        try validateMeetingLinkEnvelope(request.url)
        let calendarOnly = request.calendarOnly == true
        guard !recoveryPaused else { throw ServiceFailure.deviceBusy }
        if !calendarOnly, controlling || reserved != nil || state.currentPhase?.isTerminal == false {
            throw ServiceFailure.deviceBusy
        }
        guard state.supportsMeetingLinkPreview == true,
              let links = source as? any MeetingLinkAudioCallService else {
            throw ServiceFailure.unsupportedOperation
        }
        guard meetingLinkPreviews.count < (calendarOnly ? 3 : 4) else { throw ServiceFailure.overloaded }
        let id = UUID()
        let read = Task {
            let url = try await validatedMeetingLink(request.url, using: links)
            try checkActive()
            return try await links.previewMeetingTitle(
                at: url,
                reference: request.reference,
                calendarOnly: calendarOnly
            )
        }
        meetingLinkPreviews[id] = read
        defer { meetingLinkPreviews[id] = nil }
        let title = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try checkActive()
        guard !read.isCancelled, !recoveryPaused,
              calendarOnly || state.currentPhase?.isTerminal != false else {
            throw CancellationError()
        }
        return title.flatMap { $0.utf8.count <= 1024 ? $0 : nil }
    }

    func cancelMeetingLinkPreviews() {
        meetingLinkPreviews.values.forEach { $0.cancel() }
    }

    func joinMeeting(_ request: JoinMeetingCall, session: ClientSessionID) async throws -> ServiceCallState {
        try checkActive()
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
        try validateMeetingLinkEnvelope(request.url)
        guard !controlling, reserved == nil, state.currentPhase?.isTerminal != false,
              !recoveryPaused else { throw ServiceFailure.deviceBusy }
        guard state.supportsMeetingLinks == true,
              let links = source as? any MeetingLinkAudioCallService else {
            throw ServiceFailure.unsupportedOperation
        }
        let media = request.media ?? MeetingJoinMedia()
        guard media == MeetingJoinMedia() || state.supportsMeetingJoinMedia == true else {
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
            target: .init(meetingURL: url, displayName: "Meeting"), phase: .connecting,
            isMuted: media.microphoneMuted
        )
        publish()
        do {
            try await links.joinMeeting(at: url, callID: request.callID, media: media)
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

    private func validateMeetingLinkEnvelope(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= 2048,
              url.scheme == "https", url.user == nil, url.password == nil else {
            throw ServiceFailure(code: "invalidRequest", details: .object([
                "callStage": .string("meetingLinkEnvelope")
            ]))
        }
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
