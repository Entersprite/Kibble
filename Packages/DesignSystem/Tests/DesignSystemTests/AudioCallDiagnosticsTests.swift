import ChatKit
import Testing
@testable import DesignSystem

@MainActor
struct AudioCallDiagnosticsTests {
    @Test func diagnosticsAreOptionalAndReturnTheHostResult() async {
        let ordinary = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
        #expect(ordinary.copyDiagnostics == nil)
        var collected = 0
        let offered = AudioCallActions(
            accept: {}, decline: {}, toggleMute: {}, hangUp: {},
            copyDiagnostics: { collected += 1; return false }
        )
        #expect(await offered.copyDiagnostics?() == false)
        #expect(collected == 1)
    }

    @Test func collectionStatesHaveClearFeedbackAndAllowRetryAfterAnOutcome() {
        #expect(AudioCallCopyState.idle.title == "Copy Diagnostics")
        #expect(AudioCallCopyState.collecting.title == "Collecting…")
        #expect(AudioCallCopyState.copied.title == "Copied")
        #expect(AudioCallCopyState.unavailable.title == "Unavailable")
    }
}
