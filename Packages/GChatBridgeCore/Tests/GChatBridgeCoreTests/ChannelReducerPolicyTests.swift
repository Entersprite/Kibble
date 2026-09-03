import Foundation
import Testing
@testable import GChatBridgeCore

/// The retry policy, per failure class.
///
/// The first test here is the bug the repo owner reported from a live run: the
/// app did not recover after losing connection for a longer period. The budget
/// was four attempts spent over about eight seconds, reset only by a clean
/// stream close - which needs a working network - so any outage longer than
/// that was permanent until relaunch.
struct ChannelReducerPolicyTests {
    /// Matches `ChannelReducerReconnectTests.connected()`'s SID literal, so a
    /// reopen that names the same session takes the "continues" branch rather
    /// than the "new session" branch - neither matters for these tests, but
    /// copying rather than guessing is what the brief this file was written
    /// from asked for.
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    /// Drives the machine to a live stream, which is where a real failure
    /// arrives from. Mirrors the setup in `ChannelReducerReconnectTests`.
    ///
    /// Written against `ChannelReducer.reduce(&state, input)` rather than a
    /// `state.apply(...)` method - `ChannelState` has no such method; the only
    /// entry point is the reducer's static `reduce`, and `apply` is a private
    /// method on the unrelated `ChannelSession` driver.
    private func listening() -> ChannelState {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: initialResponse))
        return state
    }

    @Test func aLongOutageNeverStopsRetrying() {
        var state = listening()

        // Well past the old four-attempt bound. Twenty consecutive failures
        // is a ten-minute outage at the 32-second ceiling.
        for _ in 1 ... 20 {
            let effects = ChannelReducer.reduce(&state, .failed(.transport(.timedOut)))
            #expect(!effects.contains(.finished), "the channel gave up")
            #expect(!effects.contains(where: { effect in
                if case .report = effect {
                    return true
                }
                return false
            }), "the channel reported a terminal failure")
        }

        guard case let .reconnecting(attempt) = state.phase else {
            Issue.record("expected still reconnecting, got \(state.phase)")
            return
        }
        #expect(attempt == 20)
    }

    /// The one case that must not use a clock at all. The device knows there
    /// is no network, so a timer would burn requests to learn nothing; a
    /// reachability signal answers precisely and instantly.
    @Test func noInternetAsksForANetworkSignalRatherThanATimer() {
        var state = listening()
        let effects = ChannelReducer.reduce(&state, .failed(.transport(.notConnectedToInternet)))
        #expect(effects == [.awaitNetwork(attempt: 1)])
    }

    @Test func everyOtherRecoverableFailureUsesTheTimer() {
        let timed: [TransportFailureReason] = [
            .timedOut, .connectionLost, .nameResolution, .refused, .intercepted,
            .other(domain: "NSURLErrorDomain", code: -1)
        ]
        for reason in timed {
            var state = listening()
            #expect(ChannelReducer.reduce(&state, .failed(.transport(reason))) == [.reconnect(attempt: 1)])
        }
    }

    /// §4.4, and the owner took this decision with the evidence gap in view:
    /// neither status has been observed from Chat, and the justification is
    /// HTTP semantics - 429 means retry later by definition, 5xx is a
    /// server-side error whose standard remedy is a retry.
    @Test func rateLimitingAndServerErrorsNowRecover() {
        for status in [429, 500, 502, 503, 599] {
            var state = listening()
            let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(status)))
            #expect(
                effects == [.reconnect(attempt: 1)],
                "status \(status) should recover"
            )
        }
    }

    @Test func credentialFailuresStayTerminal() {
        for status in [401, 403] {
            var state = listening()
            let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(status)))
            #expect(effects.contains(.finished), "status \(status) should be terminal")
        }
    }

    /// A body that *ends* is proof the channel worked. A connection *lost* is
    /// not, and treating it as proof is what once made a retry loop run at
    /// about five requests a second forever - see `ChannelState.attempt`.
    ///
    /// **Ruling R2:** the brief this test came from passed `initialResponse:
    /// nil` to the second `.streamOpened`, but from `.handshaking` a nil
    /// initial response hits the "handshake answered 200 and named no
    /// session" branch, which stops the machine (`.noSessionIdentifier`) -
    /// terminal, not the reconnecting state this test is about. The second
    /// handshake below carries a real SID-bearing literal instead, so the
    /// machine actually reaches `.listening` before the second failure.
    @Test func aDroppedConnectionDoesNotEarnTheBudgetBack() {
        var state = listening()
        _ = ChannelReducer.reduce(&state, .failed(.transport(.connectionLost)))
        _ = ChannelReducer.reduce(&state, .retry)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: initialResponse))
        _ = ChannelReducer.reduce(&state, .failed(.transport(.connectionLost)))

        guard case let .reconnecting(attempt) = state.phase else {
            Issue.record("expected reconnecting")
            return
        }
        #expect(attempt == 2)
    }

    /// Same R2 correction as `aDroppedConnectionDoesNotEarnTheBudgetBack`
    /// above: the second handshake needs a real SID to reach `.listening`
    /// rather than tripping `.noSessionIdentifier` on a nil one.
    @Test func aCleanBodyEndDoesEarnItBack() {
        var state = listening()
        _ = ChannelReducer.reduce(&state, .failed(.transport(.timedOut)))
        _ = ChannelReducer.reduce(&state, .retry)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: initialResponse))
        _ = ChannelReducer.reduce(&state, .bodyEnded)

        #expect(state.attempt == 0)
    }
}
