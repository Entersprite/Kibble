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

    @Test func startupDoesNotPresentAnIdleConnectionAsAFailure() {
        #expect(StatusStrip.headline(for: ChatSceneState()) == nil)
    }

    @Test func ordinaryStartupUsesProgressUntilConnected() {
        var state = ChatSceneState()
        for connection in [ConnectionState.idle, .connecting, .connected] {
            state.connection = connection
            let expected: StatusStrip.Headline? = connection == .connecting ? .progress("Connecting…") : nil
            #expect(StatusStrip.headline(for: state) == expected)
        }
    }

    @Test func unfamiliarConnectionStatesUseProgressRatherThanWarnings() {
        let state = ChatSceneState(connection: .unknown("future"))
        #expect(StatusStrip.headline(for: state) == .progress("Connecting…"))
    }

    @Test func realErrorsDuringStartupAreStillShownImmediately() {
        for connection in [ConnectionState.idle, .connecting, .connected] {
            let state = ChatSceneState(connection: connection, lastError: .notAuthenticated)
            #expect(StatusStrip
                .headline(for: state) == .warning("Signed out. Sign in again to keep syncing."))
        }
    }

    @Test func actualConnectionLossRemainsAWarningAndRecoveryClearsIt() {
        var state = ChatSceneState(connection: .disconnected(reason: nil, issue: nil))
        #expect(StatusStrip.headline(for: state) == .warning("Disconnected."))
        state.connection = .reconnecting(attempt: 1, issue: .dropped, detail: nil)
        #expect(StatusStrip.headline(for: state) == .warning("Reconnecting…"))
        state.connection = .connected
        #expect(StatusStrip.headline(for: state) == nil)
    }

    @Test func connectedAndQuietIsNothing() {
        var state = ChatSceneState()
        state.connection = .connected
        #expect(StatusStrip.headline(for: state) == nil)
    }

    @Test func theStripUsesTheSessionsConnectionService() {
        let state = ChatSceneState(
            connection: .reconnecting(attempt: 1, issue: .unresponsive, detail: nil),
            connectionService: ConnectionService(name: "Google Chat", operatorName: "Google")
        )
        #expect(StatusStrip.headline(for: state) == .warning("Google isn't responding."))
    }
}

extension StatusStripTests {
    /// VoiceOver hears a problem as it appears, and nothing for progress or a
    /// probe's notice. (Whether VoiceOver is on is checked where it posts.)
    @Test func onlyAWarningIsAnnounced() {
        #expect(StatusStrip.announcement(for: .warning("Disconnected.")) == "Disconnected.")
        #expect(StatusStrip.announcement(for: .progress("Connecting…")) == nil)
        #expect(StatusStrip.announcement(for: .notice("Written to people-probe.txt.")) == nil)
        #expect(StatusStrip.announcement(for: nil) == nil)
    }

    @Test func resourceRefreshFailureDoesNotClaimConnectionFailure() {
        var state = ChatSceneState(connection: .connected)
        state.resourceSyncStatuses = [.init(resource: .directory, phase: .catchingUp)]
        #expect(StatusStrip.headline(for: state) == nil)
        state.resourceSyncStatuses = [.init(resource: .directory, phase: .failed)]
        #expect(StatusStrip
            .headline(for: state) == .warning("Could not refresh conversations. Showing saved data."))
        state.connection = .disconnected(reason: nil, issue: nil)
        #expect(StatusStrip.headline(for: state) == .warning("Disconnected."))
    }

    @Test func unrelatedAndOptionalResourceFailuresDoNotInterruptTheSelectedChat() {
        var state = ChatSceneState(connection: .connected)
        state.resourceSyncStatuses = [
            .init(resource: .history, conversationID: .init("another-chat"), phase: .failed),
            .init(resource: .presence, phase: .failed), .init(resource: .profiles, phase: .failed)
        ]
        #expect(StatusStrip.headline(for: state) == nil)
        state.selected = .init("another-chat")
        #expect(StatusStrip
            .headline(for: state) == .warning("Could not refresh messages. Showing saved data."))
    }
}
