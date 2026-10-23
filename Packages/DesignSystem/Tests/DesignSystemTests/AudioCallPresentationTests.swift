import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct AudioCallPresentationTests {
    @Test func hangUpCanCancelSetupAndRinging() {
        #expect(AudioCallPresentation.canHangUp(.connecting))
        #expect(AudioCallPresentation.canHangUp(.ringing))
        #expect(AudioCallPresentation.canHangUp(.connected))
        #expect(!AudioCallPresentation.canMute(.connecting))
        #expect(AudioCallPresentation.canMute(.ringing))
        #expect(AudioCallPresentation.canMute(.connected))
    }

    @Test(arguments: [AudioCallPhase.incoming, .declined, .ended, .failed])
    func unansweredAndFinishedCallsOfferNoActiveControls(_ phase: AudioCallPhase) {
        #expect(!AudioCallPresentation.canHangUp(phase))
        #expect(!AudioCallPresentation.canMute(phase))
    }

    @Test func declineAcknowledgmentIsNotCalledEnded() {
        #expect(AudioCallPresentation.status(for: .declined) == "Decline sent")
        #expect(AudioCallPresentation.status(for: .ended) == "Call ended")
    }

    @Test func onlyUnansweredCallsPulse() {
        #expect(AudioCallPresentation.isWaiting(.incoming))
        #expect(AudioCallPresentation.isWaiting(.connecting))
        #expect(AudioCallPresentation.isWaiting(.ringing))
        for phase in [AudioCallPhase.connected, .ended, .failed, .declined, .unknown("future")] {
            #expect(!AudioCallPresentation.isWaiting(phase))
        }
    }

    @Test func durationReadsLikeAClock() {
        #expect(AudioCallPresentation.duration(0) == "0:00")
        #expect(AudioCallPresentation.duration(252.9) == "4:12")
        #expect(AudioCallPresentation.duration(3852) == "1:04:12")
        #expect(AudioCallPresentation.duration(-5) == "0:00")
    }

    @Test func failureCopyFallsBackOnlyForFailedCalls() {
        var call = snapshot(.failed)
        let fallback = "The call couldn't be completed. Please try again."
        #expect(AudioCallPresentation.failureMessage(for: call) == fallback)
        call.failureMessage = "Local audio stopped; leaving the call could not be confirmed."
        #expect(AudioCallPresentation.failureMessage(for: call) == call.failureMessage)
        #expect(AudioCallPresentation.failureMessage(for: snapshot(.ended)) == nil)
    }

    @Test func noticesFollowTheControlsTheyBelongTo() {
        let devices = CallAudioDevices(microphones: [], speakers: [], notice: "Microphone unplugged.")
        let camera = CallCameraState(notice: "Camera disconnected.")
        let sharing = CallScreenShareState(phase: .preparing, notice: "Sharing stopped.")
        let ids: (AudioCallPhase) -> [String] = { phase in
            AudioCallPresentation.notices(
                phase: phase, devices: devices, camera: camera, screenSharing: sharing
            ).map(\.id)
        }
        #expect(ids(.connected) == ["audio", "camera", "share-picker", "share"])
        #expect(ids(.ringing) == ["audio", "camera", "share-picker", "share"])
        // Camera and sharing controls appear only once media can flow.
        #expect(ids(.connecting) == ["audio"])
        #expect(ids(.ended) == [])
        #expect(ids(.failed) == [])
    }

    @Test func copyFeedbackIsANoticeOnlyOnceRequested() {
        #expect(AudioCallCopyState.idle.notice == nil)
        #expect(AudioCallCopyState.collecting.notice?.kind == .progress)
        #expect(AudioCallCopyState.copied.notice?.kind == .success)
        #expect(AudioCallCopyState.unavailable.notice?.kind == .warning)
    }

    private func snapshot(_ phase: AudioCallPhase) -> AudioCallSession {
        AudioCallSession(AudioCallSnapshot(
            id: UUID(),
            recipient: AudioCallRecipient(
                conversationID: Conversation.ID("presentation"), memberID: Member.ID("peer"),
                displayName: "Maya"
            ),
            direction: .outgoing, phase: phase
        ))
    }
}
