import ChatKit
import Foundation

public extension AudioCallController {
    func performActivity(_ activity: CallActivity) async throws {
        try await runActivity(activity, alsoTranscription: false)
    }

    func setRecordingAndTranscriptionEnabled(_ enabled: Bool, captionLanguage: String? = nil) async throws {
        try await runActivity(
            CallActivity("recording", enabled: enabled, recordingCaptionLanguage: captionLanguage),
            alsoTranscription: true
        )
    }

    private func runActivity(_ activity: CallActivity, alsoTranscription: Bool) async throws {
        try Task.checkCancellation()
        guard let call, call.phase == .connected, !isEnding, activityTask == nil,
              let activities = service as? any CallActivitiesService else { throw CancellationError() }
        let epoch = generation
        let task = Task {
            try Task.checkCancellation()
            if alsoTranscription {
                try await runCapturePair(activity, through: activities, epoch: epoch, id: call.id)
            } else {
                try await activities.performCallActivity(activity, callID: call.id)
            }
        }
        activityTask = task
        defer {
            if generation == epoch, self.call?.id == call.id {
                activityTask = nil
                returnToMainRoomOnClosure()
            }
        }
        if [
            "endConference", "removeParticipant", "blockParticipant", "respondToAdmissions",
            "sendParticipantToWaitingRoom", "setPinForEveryone"
        ].contains(activity.action) {
            // These explicit commands stay with the call after the confirmation closes.
            try await task.value
        } else {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        guard !Task.isCancelled, generation == epoch,
              self.call?.id == call.id else { throw CancellationError() }
    }

    private func runCapturePair(
        _ recording: CallActivity, through activities: any CallActivitiesService, epoch: Int, id: UUID
    ) async throws {
        try checkCaptureScope(epoch: epoch, id: id)
        guard let state = interaction?.activities,
              state.canSetRecordingAndTranscriptionEnabled(recording.enabled),
              state.acceptsRecordingCaptionChoice(recording)
        else {
            throw ChatError.unsupported(capability: "pairedMeetingCapture")
        }
        let recordingConfirmed: Bool
        do {
            try await activities.performCallActivity(recording, callID: id)
            recordingConfirmed = true
        } catch {
            // A paired start needs the recording, but each requested stop is independent.
            if recording.enabled {
                throw error
            }
            recordingConfirmed = false
        }
        try checkCaptureScope(epoch: epoch, id: id)
        do {
            try await activities.performCallActivity(
                CallActivity("transcription", enabled: recording.enabled),
                callID: id
            )
        } catch {
            try checkCaptureScope(epoch: epoch, id: id)
            throw recordingConfirmed ? CallArtifactPairError.transcriptionUnconfirmed : .bothUnconfirmed
        }
        try checkCaptureScope(epoch: epoch, id: id)
        if !recordingConfirmed {
            throw CallArtifactPairError.recordingUnconfirmed
        }
    }

    private func checkCaptureScope(epoch: Int, id: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch, call?.id == id, call?.phase == .connected, !isEnding, !isRecovering else {
            throw CancellationError()
        }
    }
}

public extension AudioCallController {
    var currentBreakoutRoomID: UUID? {
        guard let url = activeMeetingURL else { return nil }
        return interaction?.activities?.rooms.first { $0.joinURL == url }?.id
    }

    func joinBreakoutRoom(_ id: UUID?) async throws {
        guard let activities = interaction?.activities, activities.breakoutClosing != true,
              let room = activities.rooms.first(where: { $0.id == id }), room.isOpen,
              let url = room.joinURL else { throw CancellationError() }
        try await beginMeetingHandoff(to: url, returning: false).value
    }

    func returnFromBreakoutRoom() async throws {
        guard let url = breakoutReturnURL else { throw CancellationError() }
        try await beginMeetingHandoff(to: url, returning: true).value
    }

    private var activeMeetingURL: URL? {
        guard let call, !call.phase.isTerminal,
              case let .conversation(target) = call.target else { return nil }
        return target.meetingURL
    }

    private func awaitMeetingTermination(_ id: UUID, epoch: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while sourceTermination?.id != id {
            try Task.checkCancellation()
            guard generation == epoch, ContinuousClock.now < deadline,
                  call?.id == id else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let terminal = sourceTermination, terminal.failureMessage == nil,
              [.ended, .declined].contains(terminal.phase) else { throw CancellationError() }
    }

    private func beginMeetingHandoff(
        to url: URL, returning: Bool, forceMute: Bool = false
    ) throws -> Task<Void, any Error> {
        guard url != activeMeetingURL, breakoutTask == nil, let call, call.phase == .connected,
              !isEnding, canJoinMeetingLinks,
              !(call.isMuted || forceMute) || supportsMeetingJoinMedia
        else { throw CancellationError() }
        let epoch = generation
        let originalURL = interaction?.joinURL
        let media = MeetingJoinMedia(microphoneMuted: call.isMuted || forceMute)
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                if breakoutTaskToken == token {
                    breakoutTask = nil
                    breakoutTaskToken = nil
                }
            }
            try Task.checkCancellation()
            guard generation == epoch, self.call?.id == call.id, self.call?.phase == .connected,
                  !isEnding else { throw CancellationError() }
            hangUp()
            await endingTask?.value
            try await awaitMeetingTermination(call.id, epoch: epoch)
            guard !Task.isCancelled, generation == epoch, self.call?.id == call.id,
                  [.ended, .declined].contains(self.call?.phase),
                  self.call?.failureMessage == nil, !isEnding,
                  canJoinMeetingLinks,
                  joinMeeting(at: url, media: media) != nil else { throw CancellationError() }
            breakoutReturnURL = returning ? nil : breakoutReturnURL ?? originalURL
        }
        breakoutTaskToken = token
        breakoutTask = task
        // The handoff survives its source panel closing after Hang Up.
        // Account stop cancels the controller-owned task before any new Join.
        return task
    }
}

extension AudioCallController {
    func returnToMainRoomOnClosure() {
        guard activityTask == nil, let call, case let .conversation(target) = call.target,
              let roomURL = target.meetingURL, let mainURL = breakoutReturnURL, mainURL != roomURL,
              let activities = interaction?.activities, activities.breakoutClosed == true,
              activities.breakoutClosing != true,
              activities.rooms.contains(where: { $0.joinURL == roomURL && !$0.isOpen })
        else { return }
        _ = try? beginMeetingHandoff(to: mainURL, returning: true, forceMute: true)
    }

    func stopActivityWork() {
        inviteTask?.cancel(); inviteTask = nil
        breakoutTask?.cancel(); breakoutTask = nil; breakoutTaskToken = nil; breakoutReturnURL = nil
        sourceTermination = nil
        activityTask?.cancel(); activityTask = nil
    }
}
