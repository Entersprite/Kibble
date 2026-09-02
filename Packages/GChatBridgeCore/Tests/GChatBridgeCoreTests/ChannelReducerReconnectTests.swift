import Foundation
import Testing
@testable import GChatBridgeCore

/// The reducer's two recoverable failure classes: `.transport` and
/// `.unexpectedStatus(400)`.
///
/// Split out of `ChannelReducerTests` rather than added to it because that
/// file hit swiftlint's 400-line ceiling — the same trade
/// `ChannelSessionReconnectTests` made for the driver-level tests, and for the
/// same reason: `initialResponse`, `connected()` and `body()` below are copies
/// of that file's private helpers, and a few lines of duplicated scaffolding
/// is cheaper than routing them through a third type nobody reads.
///
/// **Exactly these two classes reach any of this.** `.noSessionIdentifier` and
/// `.malformedChunk` are still terminal, and `ChannelReducerTests` guards
/// that.
struct ChannelReducerReconnectTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func connected() -> ChannelState {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: initialResponse))
        return state
    }

    // MARK: - Reconnecting, for the two failure classes that earn it

    /// A dead socket is a dead socket. It says nothing about whether Google
    /// still accepts the credential, which is why this one failure class can
    /// be recovered from without the stale-session experiment session 8 §1.4
    /// makes a precondition for classifying the others.
    @Test func aTransportFailureAsksToReconnectRatherThanStopping() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .failed(.transport(.connectionLost)))
        #expect(effects == [.reconnect(attempt: 1)])
        #expect(state.phase == .reconnecting(attempt: 1))
    }

    /// The literal value 400, and only that value. A 2026-09-02 lid-close (app
    /// open, screen locked, lid closed two minutes, lid opened) produced this
    /// exact status. `reference/googlechat-master/maugclib/channel.py:408-411`
    /// raises `SIDInvalidError` for a 400 whose body says "Unknown SID"; per
    /// `exceptions.py:27-34` that is a *sibling* of `SIDExpiringError`, not a
    /// subclass, so `listen`'s in-loop `except SIDExpiringError`
    /// (`channel.py:233-239`) does not catch it and the reference rebuilds the
    /// whole channel from a fresh `_register()` — which is exactly what
    /// `.retry` already does here. `[Verify]`: the response body was not read,
    /// so "Unknown SID" is the probable cause by mechanism, not a confirmed
    /// one.
    @Test func aStatus400FailureAsksToReconnectRatherThanStopping() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(400)))
        #expect(effects == [.reconnect(attempt: 1)])
        #expect(state.phase == .reconnecting(attempt: 1))
    }

    /// The path a real 400 actually travels. `ChannelSession.openStream` feeds
    /// every handshake and reopen response through `.streamOpened`, never
    /// through a raw `.failed(.unexpectedStatus(_))` input — so a fix that
    /// only taught `failed(_:)` about 400 and left `streamOpened`'s non-200
    /// branch calling `stop()` directly would still lose every lid-close 400
    /// to the terminal path while `aStatus400FailureAsksToReconnectRatherThanStopping`
    /// above kept passing. This is the test that would have caught that gap.
    @Test func aReopenAnsweringWith400AsksToReconnectRatherThanStopping() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .bodyEnded)
        let effects = ChannelReducer.reduce(&state, .streamOpened(status: 400, initialResponse: nil))
        #expect(effects == [.reconnect(attempt: 1)])
        #expect(state.phase == .reconnecting(attempt: 1))
    }

    /// The retry re-registers from scratch rather than resuming a SID. A SID
    /// whose socket died may or may not still be live, and asking for a new one
    /// costs a round trip where guessing wrong costs the whole session.
    @Test func aRetryStartsANewRegistration() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.transport(nil)))
        let effects = ChannelReducer.reduce(&state, .retry)
        #expect(effects == [.register])
        #expect(state.phase == .registering)
    }

    /// Bounded. `RetryPolicy.default.maxAttempts` is 4, and an unbounded
    /// reconnect against an outage is a client hammering Google.
    @Test func reconnectingStopsAfterTheAttemptLimit() {
        var state = connected()
        for attempt in 1 ... 4 {
            let effects = ChannelReducer.reduce(&state, .failed(.transport(nil)))
            #expect(effects == [.reconnect(attempt: attempt)])
            _ = ChannelReducer.reduce(&state, .retry)
        }
        let effects = ChannelReducer.reduce(&state, .failed(.transport(nil)))
        #expect(effects == [.report(.transport(nil)), .finished])
        #expect(state.phase == .failed(.transport(nil)))
    }

    /// Same bound, same shape, for the other recoverable class: a channel
    /// stuck answering every reopen with 400 stops after four rather than
    /// looping forever against a possibly-dead credential.
    @Test func reconnectingFromA400StopsAfterTheAttemptLimit() {
        var state = connected()
        for attempt in 1 ... 4 {
            let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(400)))
            #expect(effects == [.reconnect(attempt: attempt)])
            _ = ChannelReducer.reduce(&state, .retry)
        }
        let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(400)))
        #expect(effects == [.report(.unexpectedStatus(400)), .finished])
        #expect(state.phase == .failed(.unexpectedStatus(400)))
    }

    /// One budget, not one per recoverable failure shape. Four attempts split
    /// between `.transport` and `.unexpectedStatus(400)` still exhausts at
    /// four, not eight (four each) — the bound exists to cap total hammering
    /// of a possibly-dead account, not to give every recoverable class its own
    /// quota.
    @Test func transportAndStatus400ShareOneRetryBudget() {
        var state = connected()
        let failures: [ChannelFailure] = [
            .transport(.timedOut), .unexpectedStatus(400), .transport(.connectionLost), .unexpectedStatus(400)
        ]
        for (index, failure) in failures.enumerated() {
            let attempt = index + 1
            let effects = ChannelReducer.reduce(&state, .failed(failure))
            #expect(effects == [.reconnect(attempt: attempt)])
            _ = ChannelReducer.reduce(&state, .retry)
        }
        let effects = ChannelReducer.reduce(&state, .failed(.transport(.notConnectedToInternet)))
        #expect(effects == [.report(.transport(.notConnectedToInternet)), .finished])
        #expect(state.phase == .failed(.transport(.notConnectedToInternet)))
    }

    /// A body that ends the way a healthy poll ends resets the count, so a
    /// client that drops once an hour all day never exhausts its attempts.
    ///
    /// §3.5: the long poll closes on its own within seconds, so a working
    /// channel reaches this input constantly and the budget is never a
    /// standing debt.
    @Test func aBodyThatEndsCleanlyResetsTheAttemptCount() {
        var state = recovered()
        #expect(state.attempt == 1)
        _ = ChannelReducer.reduce(&state, .bodyEnded)
        #expect(state.attempt == 0)
    }

    /// The other half, and the account-safety half: **opening is not proof.**
    ///
    /// This is the failure the reset used to sit in front of. Register and
    /// handshake reach HTTP 200 with a valid SID, so the stream opens - and
    /// then the body dies rather than ending. Clearing `attempt` on the open
    /// made each such cycle refund the attempt it had just spent, which is an
    /// unbounded ladder of roughly three requests every 0.5-0.75 s against a
    /// live Google account. Overnight that is six figures of requests.
    @Test func aStreamThatOnlyOpensDoesNotResetTheAttemptCount() {
        var state = recovered()
        #expect(state.attempt == 1)
        // The body dies instead of ending: the same input the driver applies
        // when a read throws.
        let effects = ChannelReducer.reduce(&state, .failed(.transport(.connectionLost)))
        #expect(effects == [.reconnect(attempt: 2)])
        #expect(state.attempt == 2)
    }

    /// A channel that has failed once, retried, and opened a fresh stream.
    /// `attempt` is 1 on the way out: the retry was spent and nothing has
    /// earned it back yet.
    private func recovered() -> ChannelState {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.transport(nil)))
        _ = ChannelReducer.reduce(&state, .retry)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(
            &state, .streamOpened(status: 200, initialResponse: initialResponse)
        )
        return state
    }
}
