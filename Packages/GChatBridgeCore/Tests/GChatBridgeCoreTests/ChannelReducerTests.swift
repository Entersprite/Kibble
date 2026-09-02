import Foundation
import Testing
@testable import GChatBridgeCore

/// The channel's state machine, as a pure function.
///
/// `(Input) -> (State, [Effect])` — the shape session 1 §9 specified for this
/// component and `SyncReducer` already uses, so the repo has one pattern rather
/// than two. Effects are **intents**, not built requests: the driver turns
/// `.reopen(sid:aid:)` into a URL with a fresh cache-buster, which keeps this
/// side free of randomness and `ChannelRequests` the only place a URL is
/// spelled.
///
/// **Three of the four failure classes are terminal here, on purpose.** The
/// inputs that would classify them — `400 Unknown SID`, a cookie expiring
/// mid-stream, a truncated payload — are recorded as uncollected in
/// `findings.md` §6, and inventing a recovery policy against the reference's
/// guesses is work that gets thrown away when the evidence arrives. So
/// `.unexpectedStatus`, `.noSessionIdentifier` and `.malformedChunk` still
/// report and stop. `.transport` does not, because a socket that died says
/// nothing about the credential — see the reconnecting section below.
struct ChannelReducerTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func connected() -> ChannelState {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: initialResponse))
        return state
    }

    private func body(_ text: String) -> ChannelInput {
        .body(Data(text.utf8))
    }

    // MARK: - Opening

    @Test func connectingRegistersFirst() {
        var state = ChannelState()
        let effects = ChannelReducer.reduce(&state, .connect)
        #expect(effects == [.register])
        #expect(state.phase == .registering)
    }

    @Test func registeringIsFollowedByTheHandshake() {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        let effects = ChannelReducer.reduce(&state, .registered)
        #expect(effects == [.handshake])
        #expect(state.phase == .handshaking)
    }

    /// The ack is fire-and-forget — the reference never inspects its response
    /// (`channel.py:440-442`) — so the machine goes straight to listening and
    /// does not wait for it. A state that waited would stall on a reply that
    /// nobody promised to send.
    @Test func theHandshakeYieldsASIDAndAcknowledgesIt() {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        let effects = ChannelReducer.reduce(
            &state,
            .streamOpened(status: 200, initialResponse: initialResponse)
        )
        #expect(effects == [.acknowledge(sid: "S3ss10n", aid: 0)])
        #expect(state.phase == .listening(sid: "S3ss10n"))
        #expect(state.highestProcessedAid == 0)
    }

    // MARK: - Receiving

    @Test func aFramedChunkIsDelivered() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, body("11\n[[1,[\"a\"]]]"))
        #expect(effects == [.deliver([ChannelArray(aid: 1, data: .array([.string("a")]))])])
    }

    @Test func aChunkSplitAcrossReadsDeliversNothingUntilItIsWhole() {
        var state = connected()
        #expect(ChannelReducer.reduce(&state, body("11\n[[1,[")).isEmpty)
        let effects = ChannelReducer.reduce(&state, body(#""a"]]]"#))
        #expect(effects == [.deliver([ChannelArray(aid: 1, data: .array([.string("a")]))])])
    }

    /// The watermark is what a reopen sends back as `AID`, so it has to track
    /// the highest array actually handed over.
    @Test func theWatermarkAdvancesToTheHighestDeliveredAid() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, body("11\n[[1,[\"a\"]]]"))
        #expect(state.highestProcessedAid == 1)
        _ = ChannelReducer.reduce(&state, body("11\n[[7,[\"b\"]]]"))
        #expect(state.highestProcessedAid == 7)
    }

    /// Out-of-order or repeated arrays must not move the watermark backwards:
    /// a lowered `AID` asks the server to resend what has already been handled.
    @Test func theWatermarkNeverGoesBackwards() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, body("11\n[[7,[\"a\"]]]"))
        _ = ChannelReducer.reduce(&state, body("11\n[[3,[\"b\"]]]"))
        #expect(state.highestProcessedAid == 7)
    }

    /// A keepalive is delivered like anything else and still advances the
    /// watermark. Swallowing it would make the next reopen re-request
    /// everything after it.
    @Test func aKeepaliveAdvancesTheWatermarkAndIsStillDelivered() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, body("14\n[[4,[\"noop\"]]]"))
        #expect(state.highestProcessedAid == 4)
        #expect(effects.count == 1)
        if case let .deliver(arrays) = effects.first {
            #expect(arrays.first?.isKeepalive == true)
        } else {
            Issue.record("expected a delivery")
        }
    }

    @Test func aReadThatCompletesNothingProducesNoEffects() {
        var state = connected()
        #expect(ChannelReducer.reduce(&state, body("11\n[[1,")).isEmpty)
    }

    // MARK: - Reopening

    /// The long poll closes on its own within seconds of the handshake, which is
    /// normal rather than an error (§3.5). A client that treats the end of the
    /// body as a failure sees one handshake and concludes nothing is arriving.
    @Test func theEndOfTheBodyReopensRatherThanFailing() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, body("11\n[[5,[\"a\"]]]"))
        let effects = ChannelReducer.reduce(&state, .bodyEnded)
        #expect(effects == [.reopen(sid: "S3ss10n", aid: 5)])
        #expect(state.phase == .reopening(sid: "S3ss10n"))
    }

    @Test func aReopenedStreamGoesBackToListening() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .bodyEnded)
        let effects = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: nil))
        #expect(effects.isEmpty)
        #expect(state.phase == .listening(sid: "S3ss10n"))
    }

    /// A reopen that mints a *new* SID resets the watermark, because the new
    /// session has its own numbering — the reference does the same
    /// (`channel.py:422-425`). Carrying the old count over would skip events.
    @Test func aReopenThatMintsANewSIDResetsTheWatermarkAndReacknowledges() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, body("11\n[[9,[\"a\"]]]"))
        _ = ChannelReducer.reduce(&state, .bodyEnded)
        let fresh = #"[[0,["c","0therS3ss","",8,12,30000]]]"#
        let effects = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: fresh))
        #expect(effects == [.acknowledge(sid: "0therS3ss", aid: 0)])
        #expect(state.phase == .listening(sid: "0therS3ss"))
        #expect(state.highestProcessedAid == 0)
    }

    /// The buffer belongs to one stream. Carrying a half-chunk across a reopen
    /// would prepend it to the next body and desynchronise the framing.
    @Test func reopeningDiscardsAPartialChunkFromTheOldStream() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, body("11\n[[1,["))
        _ = ChannelReducer.reduce(&state, .bodyEnded)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: nil))
        let effects = ChannelReducer.reduce(&state, body("11\n[[2,[\"b\"]]]"))
        #expect(effects == [.deliver([ChannelArray(aid: 2, data: .array([.string("b")]))])])
    }

    // MARK: - Failing, terminally and out loud

    @Test func aNonOKHandshakeFails() {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        let effects = ChannelReducer.reduce(&state, .streamOpened(status: 500, initialResponse: nil))
        #expect(effects == [.report(.unexpectedStatus(500)), .finished])
        #expect(state.phase == .failed(.unexpectedStatus(500)))
    }

    /// A 200 with no SID is the shape that matters: on this protocol a failure
    /// is routinely a 200, so "it worked" cannot be read off the status.
    @Test func aHandshakeWithNoSIDFails() {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        let effects = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: nil))
        #expect(effects == [.report(.noSessionIdentifier), .finished])
    }

    @Test func anUnframeableChunkFails() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, body("oops\n[[1]]"))
        #expect(effects.count == 2)
        #expect(effects.last == .finished)
        #expect(state.phase.isFailed)
    }

    @Test func aChunkOfTheWrongShapeFails() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, body("5\n[[1]]"))
        #expect(effects.last == .finished)
        #expect(state.phase.isFailed)
    }

    /// Was `aTransportFailureIsReportedAndStops`, and pinned exactly the
    /// behaviour task 4 changed. Retargeted onto `.unexpectedStatus`, which
    /// still stops: a status the channel did not expect might mean the session
    /// is dead, and session 8 §1.4 refuses to guess which. `.transport` is now
    /// `aTransportFailureAsksToReconnectRatherThanStopping`.
    @Test func aFailureThatMightMeanTheSessionIsDeadIsReportedAndStops() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(400)))
        #expect(effects == [.report(.unexpectedStatus(400)), .finished])
        #expect(state.phase == .failed(.unexpectedStatus(400)))
    }

    /// Once it has stopped it stays stopped. A machine that answered inputs
    /// after failing would keep a dead session looking alive.
    ///
    /// On a non-transport failure since task 4: a transport failure no longer
    /// stops on the first one, so it is the wrong input for a test about what
    /// a *stopped* machine does.
    @Test func nothingHappensAfterAFailure() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(400)))
        #expect(ChannelReducer.reduce(&state, body("11\n[[1,[\"a\"]]]")).isEmpty)
        #expect(ChannelReducer.reduce(&state, .bodyEnded).isEmpty)
        #expect(state.phase == .failed(.unexpectedStatus(400)))
    }

    // MARK: - Reconnecting, for the one failure class that earns it

    /// A dead socket is a dead socket. It says nothing about whether Google
    /// still accepts the credential, which is why this one failure class can
    /// be recovered from without the stale-session experiment session 8 §1.4
    /// makes a precondition for classifying the others.
    @Test func aTransportFailureAsksToReconnectRatherThanStopping() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .failed(.transport("socket died")))
        #expect(effects == [.reconnect(attempt: 1)])
        #expect(state.phase == .reconnecting(attempt: 1))
    }

    /// The retry re-registers from scratch rather than resuming a SID. A SID
    /// whose socket died may or may not still be live, and asking for a new one
    /// costs a round trip where guessing wrong costs the whole session.
    @Test func aRetryStartsANewRegistration() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.transport("x")))
        let effects = ChannelReducer.reduce(&state, .retry)
        #expect(effects == [.register])
        #expect(state.phase == .registering)
    }

    /// Bounded. `RetryPolicy.default.maxAttempts` is 4, and an unbounded
    /// reconnect against an outage is a client hammering Google.
    @Test func reconnectingStopsAfterTheAttemptLimit() {
        var state = connected()
        for attempt in 1 ... 4 {
            let effects = ChannelReducer.reduce(&state, .failed(.transport("x")))
            #expect(effects == [.reconnect(attempt: attempt)])
            _ = ChannelReducer.reduce(&state, .retry)
        }
        let effects = ChannelReducer.reduce(&state, .failed(.transport("x")))
        #expect(effects == [.report(.transport("x")), .finished])
        #expect(state.phase == .failed(.transport("x")))
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
        let effects = ChannelReducer.reduce(&state, .failed(.transport("dropped again")))
        #expect(effects == [.reconnect(attempt: 2)])
        #expect(state.attempt == 2)
    }

    /// A channel that has failed once, retried, and opened a fresh stream.
    /// `attempt` is 1 on the way out: the retry was spent and nothing has
    /// earned it back yet.
    private func recovered() -> ChannelState {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.transport("x")))
        _ = ChannelReducer.reduce(&state, .retry)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(
            &state, .streamOpened(status: 200, initialResponse: initialResponse)
        )
        return state
    }

    /// The three failure classes session 8 §1.4 refuses to guess about stay
    /// exactly as they were. This test is the guard on that refusal.
    @Test func everyOtherFailureClassIsStillTerminal() {
        for failure in [
            ChannelFailure.unexpectedStatus(400),
            .noSessionIdentifier,
            .malformedChunk("bad")
        ] {
            var state = connected()
            let effects = ChannelReducer.reduce(&state, .failed(failure))
            #expect(effects == [.report(failure), .finished])
            #expect(state.phase == .failed(failure))
        }
    }

    // MARK: - Closing

    @Test func disconnectingStopsWithoutReportingAFailure() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .disconnect)
        #expect(effects == [.finished])
        #expect(state.phase == .closed)
    }

    @Test func nothingHappensAfterClosing() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .disconnect)
        #expect(ChannelReducer.reduce(&state, .bodyEnded).isEmpty)
    }

    /// Connecting twice must not open a second channel; the reference's own
    /// listen loop is single-flight and two SIDs on one account is a way to
    /// have events delivered to the wrong one.
    @Test func connectingTwiceDoesNotOpenASecondChannel() {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        #expect(ChannelReducer.reduce(&state, .connect).isEmpty)
    }
}
