import ChatKit
import Testing
@testable import DesignSystem

/// What the strip under the toolbar says. A finished `--probe=` run is a
/// scene with a `notice` and a connection left at `.idle`, and `.idle`'s
/// banner ("Not connected.") used to win, so no probe's result was ever drawn
/// (session 51).
struct StatusStripTests {
    @Test func aProbeResultIsShownOverAnIdleConnection() {
        let state = ChatSceneState(notice: "Written to people-probe.txt.")
        #expect(StatusStrip.headline(for: state) == .notice("Written to people-probe.txt."))
    }

    @Test func aRealErrorStillOutranksAProbeResult() {
        var state = ChatSceneState(notice: "Written to people-probe.txt.")
        state.lastError = .unknown("broken")
        guard case .warning = StatusStrip.headline(for: state) else {
            Issue.record("expected the error's warning")
            return
        }
    }

    @Test func withNoNoticeAnIdleConnectionStillSaysSo() {
        #expect(StatusStrip.headline(for: ChatSceneState()) == .warning("Not connected."))
    }

    @Test func connectedAndQuietIsNothing() {
        var state = ChatSceneState()
        state.connection = .connected
        #expect(StatusStrip.headline(for: state) == nil)
    }
}
