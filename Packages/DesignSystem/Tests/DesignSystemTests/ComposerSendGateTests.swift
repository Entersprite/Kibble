import ChatKit
import Testing
@testable import DesignSystem

/// The composer's Return, made testable (mention non-members spec §2,
/// review focus 3 and 4).
struct ComposerSendGateTests {
    @Test func aSecondReturnWhileTheFirstIsCheckingIsIgnored() {
        var gate = ComposerSendGate()
        let first = gate.begin()
        let second = gate.begin()
        gate.end()
        let afterEnd = gate.begin()
        #expect(first)
        #expect(!second)
        #expect(afterEnd)
    }

    @Test func theDraftIsClearedOnlyIfItIsStillWhatWasSent() {
        let sent = ComposedMessage(text: "hi @Jane")
        #expect(ComposerSendGate.clears(draft: sent, sent: sent))
        #expect(!ComposerSendGate.clears(draft: ComposedMessage(text: "hi @Jane and more"), sent: sent))
    }
}
