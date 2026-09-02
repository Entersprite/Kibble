import Foundation
import Testing
@testable import GChatBridgeCore

/// The driver coming back from a dropped socket.
///
/// Split out of `ChannelSessionTests` rather than added to it because that file
/// hit swiftlint's 400-line ceiling. The helpers below are copies of its
/// private ones, which is the same trade `ScriptedTransport` names in
/// `LocalBridgeBackend`: a few lines of duplicated scaffolding is cheaper than
/// the alternative, and test scaffolding shared through a third type is a type
/// nobody reads.
///
/// **These tests all drive `.transport`.** `.unexpectedStatus(400)` shares the
/// same reducer machinery and the same budget - it is exercised at the
/// reducer level in `ChannelReducerTests` rather than duplicated here, since
/// nothing session-specific distinguishes how the two recoverable classes
/// drive the driver. `.noSessionIdentifier` and `.malformedChunk` are still
/// terminal, and `ChannelReducerTests` guards that too.
struct ChannelSessionReconnectTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func cookies(_ pairs: [(String, String)] = [("COMPASS", "old")]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    private func ok() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func handshakeStream(
        chunks: [String],
        dropsAfterChunks: Bool = false
    ) -> FakeHTTPTransport.Script {
        FakeHTTPTransport.Script(
            headers: HTTPHeaders([("X-HTTP-Initial-Response", initialResponse)]),
            chunks: chunks,
            dropsAfterChunks: dropsAfterChunks
        )
    }

    private func collect(_ session: ChannelSession) async -> [ChannelArray] {
        var arrays: [ChannelArray] = []
        for await array in session.events {
            arrays.append(array)
        }
        return arrays
    }

    /// The socket dies once and the session comes back on its own.
    ///
    /// `FakeHTTPTransport` refuses to improvise, so the second script running
    /// out is what plays the role of the dropped connection - and the assertion
    /// is on the request count, because a reconnect that never re-registered
    /// would leave it at the pre-failure number.
    ///
    /// That number is **five**, not two. The handshake and the reopen consume
    /// `streams`, not `responses`, so the four scripted responses feed the
    /// first `register`, its `acknowledge`, and two of the retried
    /// registrations - and every one of `RetryPolicy.default`'s four attempts
    /// sends a `register` whether or not a response is left for it. One
    /// initial plus four bounded attempts is five; the pre-failure number
    /// would have been one.
    @Test func aDroppedSocketIsRetriedWithoutEndingTheSession() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok(), ok()],
            streams: [handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"])]
        )
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate
        )
        await session.start()
        let arrays = await collect(session)

        // The array delivered before the socket died still arrived: the
        // session recovered rather than being replaced.
        #expect(arrays.map(\.aid) == [1])
        let paths = await transport.sent.map(\.url.lastPathComponent)
        #expect(paths.filter { $0.hasPrefix("register") }.count == 5)
    }

    /// Bounded, so an outage does not become a client hammering Google.
    ///
    /// This is the easy half: no stream ever opens, so nothing could have
    /// cleared the budget anyway. `aStreamThatOpensAndDiesStillExhaustsTheBudget`
    /// below is the half that was broken.
    @Test func reconnectingGivesUpAfterFourAttempts() async {
        let transport = FakeHTTPTransport(responses: [ok()], streams: [])
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate
        )
        await session.start()
        _ = await collect(session)

        let failure = await session.failure
        #expect(failure != nil)
        let registers = await transport.sent
            .filter { $0.url.lastPathComponent.hasPrefix("register") }
        #expect(registers.count <= 5)
    }

    /// The slice's actual name: it does not only *try* to come back, it comes
    /// back.
    ///
    /// Nothing could reach this path before `FakeHTTPTransport.Script` learned
    /// to drop a body. Every earlier retry died on the next script being
    /// absent, so `.resumed`, `isRecovering = false` and the reset of
    /// `ChannelState.attempt` were all written and never executed.
    ///
    /// The single equality below is doing three jobs: `.resumed` fires exactly
    /// once and only after a recovery; the arrays from the stream *after* the
    /// drop still reach the consumer; and the second ladder starts again at 1,
    /// which is the observable proof that the recovered channel got its budget
    /// back.
    ///
    /// **What clears the budget is the second stream's clean end, not its
    /// opening.** The distinction did not matter while it was written down
    /// wrongly - the reset used to live in `listen(sid:)` and this test passed
    /// either way, because the recovered stream here both opens *and* ends
    /// cleanly before the fake runs out. It matters now:
    /// `aStreamThatOpensAndDiesStillExhaustsTheBudget` is the case that only
    /// one of the two placements survives.
    @Test func aDroppedSocketRecoversAndKeepsDelivering() async {
        let events = LifecycleRecorder()
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"], dropsAfterChunks: true),
                handshakeStream(chunks: ["11\n[[2,[\"b\"]]]"])
            ]
        )
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await events.record($0) }
        )
        await session.start()
        let arrays = await collect(session)

        #expect(arrays.map(\.aid) == [1, 2])
        #expect(await events.recorded == [
            .reconnecting(attempt: 1),
            .resumed,
            // The fake runs out for good after the recovery, so the channel
            // then spends its whole budget and stops - starting from 1, not
            // from 2, because the recovered stream ended cleanly before the
            // reopen it asked for found no script left.
            .reconnecting(attempt: 1),
            .reconnecting(attempt: 2),
            .reconnecting(attempt: 3),
            .reconnecting(attempt: 4)
        ])
        // Deliberately *not* nil, and it could not be. `failure` is only ever
        // written by a `.report`, and a transport failure that reconnects
        // returns no `.report` - so the `failure = nil` beside `.resumed` in
        // `openStream` has nothing to clear and is belt-and-braces. That is
        // reviewer Minor 1, deferred rather than removed. What this asserts is
        // the true half: a recovery does not stop the channel from eventually
        // reporting the failure that does end it.
        #expect(await session.failure != nil)
    }

    /// The unbounded loop, bounded: a channel that opens and dies for ever
    /// still stops after four.
    ///
    /// Every cycle here is register + handshake + acknowledge, the stream
    /// opens with a valid `X-HTTP-Initial-Response`, and the body then
    /// **drops** rather than ending. That is what a middlebox, a VPN or a
    /// machine that sleeps and wakes produces, and against a live account it
    /// is roughly five requests a second for as long as it lasts - which is
    /// why this is an account-safety test and not a tidiness one.
    ///
    /// Six streams are scripted and only five may be consumed. The lifecycle
    /// equality is the assertion that matters: with the budget cleared by a
    /// stream that merely *opens*, the ladder never climbs past
    /// `.reconnecting(attempt: 1)` and simply repeats it until the fake runs
    /// out. Climbing 1, 2, 3, 4 and stopping is only possible if nothing in
    /// this run cleared it - and nothing did, because no body ever ended.
    @Test func aStreamThatOpensAndDiesStillExhaustsTheBudget() async {
        let events = LifecycleRecorder()
        let dying = handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"], dropsAfterChunks: true)
        let transport = FakeHTTPTransport(
            responses: Array(repeating: ok(), count: 12),
            streams: Array(repeating: dying, count: 6)
        )
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await events.record($0) }
        )
        await session.start()
        _ = await collect(session)

        #expect(await events.recorded == [
            .reconnecting(attempt: 1),
            .resumed,
            .reconnecting(attempt: 2),
            .resumed,
            .reconnecting(attempt: 3),
            .resumed,
            .reconnecting(attempt: 4),
            .resumed
        ])
        // One initial registration plus the four the budget allows. The sixth
        // scripted stream is deliberately never reached.
        let registers = await transport.sent
            .filter { $0.url.lastPathComponent.hasPrefix("register") }
        #expect(registers.count == 5)
        #expect(await session.failure != nil)
    }

    /// The host is told, so a window can say "reconnecting" rather than
    /// showing a healthy session that has quietly stopped delivering.
    @Test func theHostIsToldWhileReconnecting() async {
        let events = LifecycleRecorder()
        let transport = FakeHTTPTransport(responses: [ok()], streams: [])
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await events.record($0) }
        )
        await session.start()
        _ = await collect(session)

        let recorded = await events.recorded
        #expect(recorded.contains(.reconnecting(attempt: 1)))
    }
}

/// Records lifecycle callbacks. An actor for the same reason `Rotations` is one.
private actor LifecycleRecorder {
    private(set) var recorded: [ChannelLifecycle] = []

    func record(_ event: ChannelLifecycle) {
        recorded.append(event)
    }
}
