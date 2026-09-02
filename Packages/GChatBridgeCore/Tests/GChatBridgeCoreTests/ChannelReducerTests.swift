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
/// **Two of the four failure classes are unconditionally terminal here, on
/// purpose.** The inputs that would classify them — a cookie expiring
/// mid-stream, a truncated payload — are recorded as uncollected in
/// `findings.md` §6, and inventing a recovery policy against the reference's
/// guesses is work that gets thrown away when the evidence arrives. So
/// `.noSessionIdentifier` and `.malformedChunk` still report and stop.
/// `.transport` recovers unconditionally, and `.unexpectedStatus` recovers
/// only at the literal value 400 — see the reconnecting section below.
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

    /// Fix-round finding: a desynchronised stream puts mid-payload bytes where
    /// the length prefix belongs, and a chunk payload is JSON on one line, so
    /// "everything before the first newline" can be an entire message body -
    /// worse than the SID the transport-level fix closed, because this is
    /// message content. `String(describing:)` on the resulting
    /// `ChannelFailure` is exactly what `LocalBridgeBackend.channelStopped`
    /// wraps into `ChatError.transport(_:)`, so proving it clean here proves
    /// the `ChatError` clean too - there is no further transformation between
    /// this string and that one.
    @Test func aMalformedPrefixNeverLeaksTheBufferedTextItReplaced() {
        var state = connected()
        let secret = "SECRET-MESSAGE-CONTENT-DO-NOT-LEAK"
        let effects = ChannelReducer.reduce(&state, body(#"{"text":"\#(secret)"}"# + "\n[[1]]"))
        #expect(effects.last == .finished)
        guard case let .failed(failure) = state.phase else {
            Issue.record("expected .failed, got \(state.phase)")
            return
        }
        let description = String(describing: failure)
        #expect(!description.contains(secret))
        #expect(!description.contains("SECRET"))
    }

    @Test func aChunkOfTheWrongShapeFails() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, body("5\n[[1]]"))
        #expect(effects.last == .finished)
        #expect(state.phase.isFailed)
    }

    /// Was `aTransportFailureIsReportedAndStops`, and pinned exactly the
    /// behaviour task 4 changed. Retargeted onto `.unexpectedStatus`, which
    /// still stops for every value **except the literal 400**: a status the
    /// channel did not expect might mean the session is dead, and session 8
    /// §1.4 refuses to guess which for the classes it has not collected
    /// evidence for. 403 stands in for "a status that plausibly means the
    /// credential itself is dead" — the case this bound exists to keep from
    /// being hammered. `.transport` is
    /// `aTransportFailureAsksToReconnectRatherThanStopping`; `400` is
    /// `aStatus400FailureAsksToReconnectRatherThanStopping`.
    @Test func aFailureThatMightMeanTheSessionIsDeadIsReportedAndStops() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(403)))
        #expect(effects == [.report(.unexpectedStatus(403)), .finished])
        #expect(state.phase == .failed(.unexpectedStatus(403)))
    }

    /// Once it has stopped it stays stopped. A machine that answered inputs
    /// after failing would keep a dead session looking alive.
    ///
    /// On a non-transport, non-400 failure: both recoverable classes ask to
    /// reconnect rather than stopping on the first one, so either would be the
    /// wrong input for a test about what a *stopped* machine does.
    @Test func nothingHappensAfterAFailure() {
        var state = connected()
        _ = ChannelReducer.reduce(&state, .failed(.unexpectedStatus(403)))
        #expect(ChannelReducer.reduce(&state, body("11\n[[1,[\"a\"]]]")).isEmpty)
        #expect(ChannelReducer.reduce(&state, .bodyEnded).isEmpty)
        #expect(state.phase == .failed(.unexpectedStatus(403)))
    }

    // MARK: - Reconnecting

    // `.transport` and `.unexpectedStatus(400)` — the two failure classes that
    // reconnect rather than stop — are covered in `ChannelReducerReconnectTests`,
    // split out for the same 400-line-ceiling reason `ChannelSessionReconnectTests`
    // was split from `ChannelSessionTests`.

    /// The two failure classes session 8 §1.4 refuses to guess about stay
    /// exactly as they were, and `.unexpectedStatus` stays terminal for every
    /// value other than the literal 400 — 500 and 403 stand in for "any other
    /// status", 5xx and 4xx alike, deliberately not folded into the 400
    /// exception the way "any 4xx" or "any non-200" would have been. This test
    /// is the guard on that refusal.
    @Test func everyOtherFailureClassIsStillTerminal() {
        for failure in [
            ChannelFailure.unexpectedStatus(500),
            .unexpectedStatus(403),
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
