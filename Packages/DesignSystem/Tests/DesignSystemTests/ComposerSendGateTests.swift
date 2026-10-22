import ChatKit
import Testing
@testable import DesignSystem

/// The composer's Return is serialized while checking non-member mentions.
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

    /// The confirmation sends the message with modes set,
    /// while the draft's own mentions are plain. It is still the same draft,
    /// and must be cleared.
    @Test func aConfirmedSendClearsTheDraftItCameFrom() {
        let jane = Member.ID("jane")
        let draft = ComposedMessage(
            text: "@Jane hi",
            mentions: [Mention(target: .user(jane), start: 0, length: 5)]
        )
        let sent = draft.settingMode(.invite, for: [jane])
        #expect(ComposerSendGate.clears(draft: draft, sent: sent))
    }
}
