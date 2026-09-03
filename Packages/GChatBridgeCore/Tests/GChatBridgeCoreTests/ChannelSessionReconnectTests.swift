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
///
/// **Since task 3 of the reconnect taxonomy, `.transport` never gives up on
/// its own** - the bug the repo owner reported was exactly that it used to,
/// after four attempts. Every test below that used to rely on the fake
/// running dry to produce a clean, terminal stop now either scripts a
/// deliberate terminal status (`terminatingStream()`) or drives the session
/// on a background `Task` and calls `stop()` once enough evidence has
/// accumulated - a fake that merely runs out would otherwise retry forever
/// and hang the test, which is the change task 3 makes.
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

    /// A stream reply that stays terminal even after task 3's changes (403 is
    /// not 400, 429 or any 5xx - see `ChannelFailure.isRecoverable`), so a
    /// test can end a session deterministically.
    private func terminatingStream() -> FakeHTTPTransport.Script {
        FakeHTTPTransport.Script(status: 403, chunks: [])
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
    /// Used to assert the request count was **five**, because
    /// `RetryPolicy.default`'s four-attempt bound was spent entirely on
    /// retried registrations before the fake ran dry - "one initial plus
    /// four bounded attempts". Task 3 of the reconnect taxonomy removed that
    /// bound, so relying on the fake to run dry no longer produces a
    /// terminal stop; it would hang this test. The reopen below is scripted
    /// to drop explicitly (`dropsAfterChunks`, not exhaustion) and the
    /// retry's handshake gets a deliberate terminal status, so the session
    /// still ends after exactly one retry cycle - two registers, not five.
    @Test func aDroppedSocketIsRetriedWithoutEndingTheSession() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"]),
                FakeHTTPTransport.Script(chunks: [], dropsAfterChunks: true),
                terminatingStream()
            ]
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
        #expect(paths.filter { $0.hasPrefix("register") }.count == 2)
    }

    /// Used to assert the ladder gave up after four attempts
    /// (`RetryPolicy.default.maxAttempts`), since nothing here can ever
    /// succeed (no streams scripted, so every handshake - and eventually
    /// every register too, once the one scripted response is spent - fails).
    /// That bound is the bug the repo owner reported from a live run (an
    /// outage longer than it produced was permanent until relaunch), so task
    /// 3 of the reconnect taxonomy removed it. This now asserts the
    /// opposite: the ladder climbs straight past the old ceiling, and only
    /// an explicit `stop()` - not the ladder giving up - ends the session.
    @Test func reconnectingNeverGivesUpOnItsOwn() async {
        let events = LifecycleRecorder()
        let transport = FakeHTTPTransport(responses: [ok()], streams: [])
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await events.record($0) }
        )
        let running = Task { await session.start() }
        // Past the old four-attempt bound.
        while await events.recorded.count < 6 {
            await Task.yield()
        }
        await session.stop()
        _ = await running.value
        #expect(await session.failure == nil)
    }

    /// The slice's actual name: it does not only *try* to come back, it comes
    /// back.
    ///
    /// Nothing could reach this path before `FakeHTTPTransport.Script` learned
    /// to drop a body. Every earlier retry died on the next script being
    /// absent, so `.resumed`, `isRecovering = false` and the reset of
    /// `ChannelState.attempt` were all written and never executed.
    ///
    /// Used to assert a further ladder of `.reconnecting(attempt: 1...4)`
    /// after the recovery, spent because the fake ran dry at the
    /// post-recovery reopen and (before task 3) running dry there stopped
    /// the channel after four. Task 3 removed that stop, so running dry
    /// there would now hang this test instead of ending it - the third
    /// stream below scripts a deliberate terminal status for that reopen so
    /// the session still ends deterministically. What remains and is still
    /// the point: `.resumed` fires exactly once, right after the recovery,
    /// and the arrays from the stream *after* the drop still reach the
    /// consumer.
    @Test func aDroppedSocketRecoversAndKeepsDelivering() async {
        let events = LifecycleRecorder()
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"], dropsAfterChunks: true),
                handshakeStream(chunks: ["11\n[[2,[\"b\"]]]"]),
                terminatingStream()
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
            .resumed
        ])
        // Deliberately *not* nil. `failure` is only ever written by a
        // `.report`, and a transport failure that reconnects returns no
        // `.report` - so what proves the recovery actually happened is the
        // terminal failure that ends the session afterwards, at the
        // deliberately-scripted reopen above.
        #expect(await session.failure != nil)
    }

    /// Was "the unbounded loop, bounded: a channel that opens and dies for
    /// ever still stops after four" - the account-safety bound this pinned
    /// is the bug the repo owner reported (task 3 of the reconnect
    /// taxonomy): an outage longer than four attempts' worth was permanent
    /// until relaunch. This now asserts the opposite - the ladder keeps
    /// climbing well past the old ceiling - which is exactly why
    /// `ChannelState.attempt` still resets only on a clean body end and
    /// never on stream-*open*: removing the four-attempt bound without that
    /// distinction would have reintroduced the ~5-requests-a-second
    /// hammering incident `ChannelState.attempt`'s doc comment records,
    /// instead of fixing anything. Every cycle here is still register +
    /// handshake + acknowledge, opening with a valid
    /// `X-HTTP-Initial-Response` and then dying rather than ending - the
    /// exact shape a middlebox, a VPN or a machine that sleeps and wakes
    /// produces.
    @Test func aStreamThatOpensAndDiesKeepsRetryingPastTheOldBudget() async {
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
        let running = Task { await session.start() }
        // The old bound stopped at attempt 4. Once the six scripted streams
        // (and the twelve scripted responses) run out too, the ladder keeps
        // climbing anyway via plain transport exhaustion - proof that
        // nothing here, opening-and-dying or otherwise, gives up on its own.
        while await !(events.recorded.contains(.reconnecting(attempt: 5))) {
            await Task.yield()
        }
        await session.stop()
        _ = await running.value
        #expect(await session.failure == nil)
    }

    /// The host is told, so a window can say "reconnecting" rather than
    /// showing a healthy session that has quietly stopped delivering.
    @Test func theHostIsToldWhileReconnecting() async {
        let events = LifecycleRecorder()
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: [], dropsAfterChunks: true),
                terminatingStream()
            ]
        )
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
