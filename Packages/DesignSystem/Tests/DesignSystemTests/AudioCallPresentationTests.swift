import ChatKit
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
        #expect(AudioCallPresentation.status(for: .ended) == "Ended")
    }
}
