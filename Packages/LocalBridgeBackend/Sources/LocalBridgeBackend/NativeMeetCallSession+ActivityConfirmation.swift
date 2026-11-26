import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func confirmActivityWrite(_ activity: CallActivity, baseline: Set<UUID>, fields: [Int]) async throws {
        if fields.isEmpty {
            _ = try await readActivityState(requiring: [])
            try confirmActivity(activity, baseline: baseline)
            return
        }

        // Meet can acknowledge a write before the new state is published.
        // Retry only the readback, within one deadline for both waits and reads.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            if try await readActivityState(requiring: fields, timeout: remaining) != nil,
               (try? confirmActivity(activity, baseline: baseline)) != nil {
                return
            }
            let pause = min(.milliseconds(400), ContinuousClock.now.duration(to: deadline))
            if pause > .zero {
                try await Task.sleep(for: pause)
            }
        }
        throw ChatError.transport("The meeting activity could not be confirmed.")
    }

    func confirmActivity(_ activity: CallActivity, baseline: Set<UUID>) throws {
        let confirmed: Bool
        switch activity.action {
        case "recording", "transcription", "notes":
            let artifact = activities.artifacts.first { $0.kind == activity.action }
            let phase = artifact?.phase
            let matchesPhase = activity.enabled
                ? phase == "active" || phase == "starting" : phase == "stopped"
            let matchesCaptions = activity.recordingCaptionLanguage
                .map { $0 == artifact?.recordingCaptionLanguage }
            confirmed = matchesPhase && matchesCaptions != false
        case "attendance": confirmed = activities.attendanceReportEnabled == activity.enabled
        case "createPoll": confirmed = activities.polls.contains {
                !baseline.contains($0.id) && $0.question == activity.text && $0.options == activity.options
            }
        case "askQuestion": confirmed = activities.questions
            .contains { !baseline.contains($0.id) && $0.text == activity.text }
        default: confirmed = confirmAddressedActivity(activity, baseline: baseline)
        }
        guard confirmed else { throw ChatError.transport("The meeting activity could not be confirmed.") }
    }

    private func confirmAddressedActivity(_ activity: CallActivity, baseline: Set<UUID>) -> Bool {
        switch activity.action {
        case "sharePollResults": activities.polls.first { $0.id == activity.resourceID }?
            .resultsVisible == activity.enabled
        case "closePoll": activities.polls.first { $0.id == activity.resourceID }?.isOpen == false
        case "votePoll": activities.polls.first { $0.id == activity.resourceID }?.selections == activity
            .selections
        case "answerQuestion": activities.questions.first { $0.id == activity.resourceID }?.isAnswered == true
        case "voteQuestion": activities.questions.first { $0.id == activity.resourceID }?.hasVoted == activity
            .enabled
        case "createRooms", "createAndOpenRooms": Set(activities.rooms.filter {
                $0.isOpen && !baseline.contains($0.id)
            }.map(\.name))
                .isSuperset(of: activity.options)
        case "openRooms",
             "closeRooms": !activities.rooms.isEmpty && activities.rooms
            .allSatisfy { $0.isOpen == (activity.action == "openRooms") }
        case "assignRoom": activities.rooms.first { $0.id == activity.resourceID }
            .map { Set($0.participants) == Set(activity.participantIDs) } == true
        default: false
        }
    }
}
