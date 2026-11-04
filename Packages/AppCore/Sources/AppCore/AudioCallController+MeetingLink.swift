import ChatKit
import Foundation

public extension AudioCallController {
    var meetingLinkHosts: Set<String> {
        guard canJoinMeetingLinks else { return [] }
        return supportedMeetingLinkHosts
    }

    var canJoinMeetingLinks: Bool {
        isAvailable && !isRecovering && supportsMeetingLinks
    }

    @discardableResult
    func joinMeeting(at url: URL) -> UUID? {
        if raiseCurrentCall() {
            return nil
        }
        guard canJoinMeetingLinks, let links = service as? any MeetingLinkAudioCallService else { return nil }
        return begin(AudioCallSession(.init(
            id: UUID(), target: ConversationCallTarget(meetingURL: url, displayName: "Meeting"),
            phase: .connecting
        ), isJoining: true)) { id in try await links.joinMeeting(at: url, callID: id) }
    }
}
