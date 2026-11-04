import ChatKit
import Foundation

public extension AudioCallController {
    func performActivity(_ activity: CallActivity) async throws {
        guard let call, call.phase == .connected, !isEnding, activityTask == nil,
              let activities = service as? any CallActivitiesService else { throw CancellationError() }
        let epoch = generation
        let task = Task { try await activities.performCallActivity(activity, callID: call.id) }
        activityTask = task
        defer {
            if generation == epoch {
                activityTask = nil
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == epoch,
              self.call?.id == call.id else { throw CancellationError() }
    }
}

public extension AudioCallController {
    func joinBreakoutRoom(_ id: UUID?) async throws {
        guard let room = interaction?.activities?.rooms.first(where: { $0.id == id }), room.isOpen,
              let url = room.joinURL else { throw CancellationError() }
        try await switchMeeting(to: url, returning: false)
    }

    func returnFromBreakoutRoom() async throws {
        guard let url = breakoutReturnURL else { throw CancellationError() }
        try await switchMeeting(to: url, returning: true)
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

    private func switchMeeting(to url: URL, returning: Bool) async throws {
        guard breakoutTask == nil, let call, call.phase == .connected,
              canJoinMeetingLinks else { throw CancellationError() }
        let epoch = generation
        let originalURL = interaction?.joinURL
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            hangUp()
            await endingTask?.value
            try await awaitMeetingTermination(call.id, epoch: epoch)
            guard !Task.isCancelled, generation == epoch, self.call?.id == call.id,
                  [.ended, .declined].contains(self.call?.phase),
                  self.call?.failureMessage == nil, !isEnding,
                  canJoinMeetingLinks else { throw CancellationError() }
            guard joinMeeting(at: url) != nil else { throw CancellationError() }
            breakoutReturnURL = returning ? nil : breakoutReturnURL ?? originalURL
        }
        let token = UUID()
        breakoutTaskToken = token
        breakoutTask = task
        defer {
            if breakoutTaskToken == token {
                breakoutTask = nil; breakoutTaskToken = nil
            }
        }
        // The explicit handoff survives its source panel closing after Hang Up.
        // Account stop cancels the controller-owned task before any new Join.
        try await task.value
    }
}

extension AudioCallController {
    func stopActivityWork() {
        inviteTask?.cancel(); inviteTask = nil
        breakoutTask?.cancel(); breakoutTask = nil; breakoutTaskToken = nil; breakoutReturnURL = nil
        sourceTermination = nil
        activityTask?.cancel(); activityTask = nil
    }
}
