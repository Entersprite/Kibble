import ChatKit
import Foundation
import GChatBridgeCore

extension NativeMeetCallSession {
    func confirmActivity(_ activity: CallActivity, baseline: Set<UUID>) throws {
        let confirmed: Bool
        switch activity.action {
        case "recording", "transcription", "notes":
            let phase = activities.artifacts.first { $0.kind == activity.action }?.phase
            confirmed = activity.enabled ? phase == "active" || phase == "starting" : phase == "stopped"
        case "attendance": confirmed = activities.attendanceReportEnabled == activity.enabled
        case "createPoll": confirmed = activities.polls
            .contains { !baseline.contains($0.id) && $0.question == activity.text }
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
        case "createRooms": Set(activities.rooms.filter { !baseline.contains($0.id) }.map(\.name))
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
