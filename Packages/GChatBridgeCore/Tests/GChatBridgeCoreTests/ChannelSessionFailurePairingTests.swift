import Foundation
import Testing
@testable import GChatBridgeCore

/// The tests that drive a session on a background `Task` and bound the wait
/// with `startAndWait`, split out of `ChannelSessionReconnectTests` once fix
/// round 1's Finding 1 fix (a new reproduction test, plus `DualFailureTransport`)
/// pushed that file past swiftlint's 400-line ceiling - the same trade that
/// file's own doc comment already made once, splitting out of
/// `ChannelSessionTests` for the identical reason. The helpers below
/// (`cookies`, `ok`, `handshakeStream`, `startAndWait`, `LifecycleRecorder`,
/// `CompletionFlag`) are copies of `ChannelSessionReconnectTests`'s own
/// private ones: a few lines of duplicated scaffolding is cheaper than the
/// alternative, and test scaffolding shared through a third type is a type
/// nobody reads.
struct ChannelSessionFailurePairingTests {
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

    /// Starts `body` on a background `Task` and waits for `condition` to
    /// become true, without ever hanging the suite if it does not. Returns
    /// the `Task` so the caller can `stop()` the session and await it.
    ///
    /// See `ChannelSessionReconnectTests`'s own copy of this helper for the
    /// full history (fix round 1 finding, Critical, from that file's own
    /// numbering) of why it is shaped this way rather than racing
    /// `running.value` against the poll.
    private func startAndWait(
        _ body: @escaping @Sendable () async -> Void,
        observed: @escaping @Sendable () async -> String,
        until condition: @escaping @Sendable () async -> Bool
    ) async -> Task<Void, Never> {
        let doneFlag = CompletionFlag()
        let running = Task {
            await body()
            await doneFlag.markDone()
        }
        // Ten seconds is generous on purpose: every condition this is used
        // for is satisfied in well under a millisecond when the fix is in
        // place, so this is a hang guard, not a realistic timing budget - a
        // slow CI machine should never come close to it.
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if await condition() {
                break
            }
            if await doneFlag.isDone {
                await Issue.record("""
                the channel finished on its own before the expected condition was met - \
                the pre-task-3 four-attempt bound may have reoccurred. Observed: \(observed())
                """)
                break
            }
            if ContinuousClock.now >= deadline {
                await Issue.record("""
                timed out waiting for the expected condition - a hang guard, not the real \
                assertion. Observed: \(observed())
                """)
                break
            }
            await Task.yield()
        }
        return running
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
        // Past the old four-attempt bound.
        let running = await startAndWait {
            await session.start()
        } observed: {
            await "recorded \(events.recorded)"
        }
        until: {
            await events.recorded.count >= 6
        }
        await session.stop()
        _ = await running.value
        #expect(await session.failure == nil)
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
        // The old bound stopped at attempt 4. Once the six scripted streams
        // (and the twelve scripted responses) run out too, the ladder keeps
        // climbing anyway via plain transport exhaustion - proof that
        // nothing here, opening-and-dying or otherwise, gives up on its own.
        let running = await startAndWait {
            await session.start()
        } observed: {
            await "recorded \(events.recorded)"
        }
        until: {
            await events.recorded.contains(.reconnecting(attempt: 5, failure: .transport(nil)))
        }
        await session.stop()
        _ = await running.value
        #expect(await session.failure == nil)
    }

    /// Was "a transport failure ends the stream rather than hanging it" -
    /// task 3 of the reconnect taxonomy made that literally false: a
    /// transport failure no longer ends a session on its own, it reconnects
    /// forever (that is the fix for the reported bug). The fake here can
    /// never succeed (nothing is scripted), so the ladder climbs
    /// indefinitely; this now asserts that it really does climb well past the
    /// old four-attempt bound, and that only an explicit `stop()` ends it.
    @Test func aTransportFailureNoLongerEndsTheSessionOnItsOwn() async {
        let transport = FakeHTTPTransport(responses: [], streams: [])
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        // Past the old four-attempt bound (five register calls, including the
        // first), and still climbing - proof the ladder does not give up on
        // its own. `stop()` below is what ends it.
        let running = await startAndWait {
            await session.start()
        } observed: {
            await "sent \(transport.sent.count) requests"
        }
        until: {
            await transport.sent.count >= 10
        }
        await session.stop()
        _ = await running.value
        #expect(await session.failure == nil)
    }

    /// Fix round 1, Finding 1: reproduces the exact ordering the review
    /// traced, concretely rather than hypothetically.
    ///
    /// `openStream` can apply **two separate** `.failed(_:)` inputs before
    /// `run()`'s loop ever gets a turn to dequeue either one's `.reconnect`
    /// effect: a freshly-opened stream with a *new* SID queues `.acknowledge`
    /// and drains it immediately via `acknowledgeIfPending()`, all still
    /// inside the same `openStream()` call - so if that acknowledge's
    /// `send()` fails, and then the same call's body read *also* fails
    /// before returning, both failures are applied back-to-back with no
    /// intervening turn of the driver loop. `DualFailureTransport` below
    /// forces exactly that: the acknowledge's `send()` throws a classified
    /// `.timedOut`, and the handshake's body throws a classified
    /// `.connectionLost` the instant it is read - two distinct, identifiable
    /// reasons, on purpose, so a swapped pairing is visible rather than
    /// silently identical.
    ///
    /// Before the fix (a session-wide `lastFailure`, read when the effect is
    /// later *dequeued*), attempt 1 reported `.connectionLost` - the second
    /// failure, not the one that actually caused it. The fix snapshots the
    /// failure into the queued effect at the moment it is *enqueued*, which
    /// is what this test pins.
    @Test func eachReconnectAttemptCarriesTheFailureThatCausedIt() async {
        let events = LifecycleRecorder()
        let transport = DualFailureTransport(initialResponse: initialResponse)
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await events.record($0) }
        )
        let running = await startAndWait {
            await session.start()
        } observed: {
            await "recorded \(events.recorded)"
        }
        until: {
            await events.recorded.count >= 2
        }
        await session.stop()
        _ = await running.value

        let recorded = await events.recorded
        // The ack's `send()` fails first, with `.timedOut`; the freshly-opened
        // body fails second (and immediately - no chunks are scripted), with
        // `.connectionLost`. Attempt 1 must carry the first, attempt 2 the
        // second - not swapped, and not both carrying whichever happened to
        // be applied last.
        #expect(recorded.first == .reconnecting(attempt: 1, failure: .transport(.timedOut)))
        #expect(recorded.count >= 2)
        if recorded.count >= 2 {
            #expect(recorded[1] == .reconnecting(attempt: 2, failure: .transport(.connectionLost)))
        }
    }
}

/// Fails its acknowledge and its body independently, with two distinct
/// classified reasons - see `eachReconnectAttemptCarriesTheFailureThatCausedIt`'s
/// own doc comment for why this is written as a dedicated fake rather than
/// reusing `FakeHTTPTransport`: that fixture's own failures (`Exhausted`,
/// `Dropped`) are both unclassified and both collapse to `.transport(nil)`,
/// which cannot tell a swapped pairing from a correct one.
private actor DualFailureTransport: HTTPTransport {
    private var sendCount = 0
    private let initialResponse: String

    init(initialResponse: String) {
        self.initialResponse = initialResponse
    }

    /// The first call is `register`, which must succeed so the handshake -
    /// and therefore the acknowledge this test is actually about - is ever
    /// reached. Every call after that (the acknowledge, and every register
    /// retried afterwards) fails the same classified way, distinct from the
    /// body's own failure below.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sendCount += 1
        guard sendCount == 1 else {
            throw ClassifiedTransportFailure(.timedOut)
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    /// Every stream opens with a valid, *new* SID (so `streamOpened` queues
    /// an `.acknowledge`) and then fails immediately on the first body read -
    /// no chunks are yielded, so nothing here depends on timing.
    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        HTTPStream(
            status: 200,
            headers: HTTPHeaders([("X-HTTP-Initial-Response", initialResponse)]),
            body: AsyncThrowingStream { continuation in
                continuation.finish(throwing: ClassifiedTransportFailure(.connectionLost))
            }
        )
    }
}

/// Records lifecycle callbacks. An actor for the same reason `Rotations` is one.
private actor LifecycleRecorder {
    private(set) var recorded: [ChannelLifecycle] = []

    func record(_ event: ChannelLifecycle) {
        recorded.append(event)
    }
}

/// Set by `startAndWait`'s wrapped `body`, from inside its own task, the
/// instant it returns - see that helper's doc comment for why this exists
/// instead of a sibling task awaiting `Task.value`.
private actor CompletionFlag {
    private(set) var isDone = false

    func markDone() {
        isDone = true
    }
}
