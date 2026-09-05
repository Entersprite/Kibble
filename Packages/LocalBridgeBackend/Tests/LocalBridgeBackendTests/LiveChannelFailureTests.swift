import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The bridge's live channel, failing.
///
/// Split out of `LiveChannelTests` (that file's own former "Failing" section)
/// once fix round 1's Finding 3 fix (`channelStopped` populating `issue`,
/// plus its two covering tests) pushed that file past swiftlint's 400-line
/// ceiling. The helpers below are copies of `LiveChannelTests`'s own private
/// ones - the same trade that file's own doc comment already describes for
/// `ScriptedTransport` itself: a few lines of duplicated scaffolding is
/// cheaper than sharing through a third type nobody reads.
@Suite(.timeLimit(.minutes(1)))
struct LiveChannelFailureTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func shell() -> Result<HTTPResponse, any Error> {
        ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi"))
    }

    /// A `MESSAGE_POSTED` chunk in the shape §12 recorded, framed for the wire.
    private func messageChunk(aid: Int, text: String) -> String {
        let group = #"[null,null,["dm-1"]]"#
        let topic = #"[null,"t-1",\#(group)]"#
        let parent = "[null,null,null,\(topic)]"
        let identifier = #"[\#(parent),"m-\#(aid)"]"#
        let padding = Array(repeating: "null", count: 6).joined(separator: ",")
        let message = #"[\#(identifier),[["u-1"]],"1700000000000000",\#(padding),"\#(text)"]"#
        let body = "[null,null,null,null,null,[\(message)],null,null,null,null,null,6]"
        let event = "[null,null,null,null,null,null,null,[\(body)]]"
        let payload = #"[[\#(event),"wrapper"]]"#
        let array = "[[\(aid),\(payload)]]"
        return "\(array.utf16.count)\n\(array)"
    }

    /// Collects every event emitted within `duration`, rather than a fixed
    /// count. See `LiveChannelTests.collectEvents`'s own doc comment for why:
    /// `connect()` races the channel's handshake against
    /// `resolveAndEmitSelf()`, so a fixed count either cuts off early or
    /// hangs waiting for an event this finite scenario will never produce.
    private func collectEvents(
        _ backend: LocalBridgeBackend,
        for duration: Duration = .milliseconds(300)
    ) async -> [ChatEvent] {
        let collector = Task<[ChatEvent], Never> {
            var events: [ChatEvent] = []
            for await event in backend.events {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
    }

    /// A bootstrap that says "signed out" must not go on to open a channel with
    /// credentials that have already been refused.
    @Test func aRejectedSessionOpensNoChannel() async {
        let transport = ScriptedTransport(
            [ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "AccountsSignInUi"))]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        _ = try? await backend.connect()
        #expect(await !backend.isRunningChannel)
    }

    /// The channel stopping is not silent - a window still has to be told, or
    /// it shows a session that looks healthy and has stopped delivering.
    ///
    /// Was "since task 4 `ChannelSession` reconnects from a dead socket, but
    /// only four times - so it still stops". Task 3 of the reconnect
    /// taxonomy removed that stop entirely: a dead socket (a `.transport`
    /// failure, which is what no streams being scripted used to produce)
    /// now reconnects forever rather than ending the channel, which is the
    /// bug the repo owner reported. `waitForChannel()` below would hang
    /// waiting for a channel that never gives up on its own, so the
    /// handshake here is scripted to answer with a status that stays
    /// terminal even after task 3 widened `.unexpectedStatus`'s recoverable
    /// range (429 and 5xx - see `ChannelFailure.isRecoverable`); 403 is
    /// neither.
    ///
    /// Five non-shell responses, generously: `connect()` races
    /// `resolveAndEmitSelf()`'s `get_self_user_status` against the channel's
    /// own `register`, acknowledge and (Part 1's addition) initial ping for
    /// this same queue - four real consumers - and with too few responses,
    /// whichever loses used to produce a `.transport` failure that the old
    /// four-attempt bound absorbed and stopped on regardless. That bound is
    /// gone, so a lost race at `register`/acknowledge/ping now retries
    /// forever without ever reaching the terminal stream scripted below - a
    /// hang (with `retry: .immediate`, a tight spin rather than a true wait)
    /// that depends on scheduling order rather than reliably reproducing.
    @Test func aChannelFailureIsReportedOnTheEventStream() async throws {
        let transport = ScriptedTransport(
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [ScriptedTransport.Script(status: 403, chunks: [])]
        )
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .immediate
        )
        try await backend.connect()
        // Waiting for the channel to actually stop makes the later collect
        // deterministic, and nothing has consumed the stream yet - the
        // events are all still buffered when the collector starts.
        await backend.waitForChannel()

        let received = await collectEvents(backend)
        #expect(received.contains {
            if case .backendError = $0 {
                true
            } else {
                false
            }
        })
    }

    /// The domain's half of the recovery: a window is told the channel is
    /// coming back, and then told it is back.
    ///
    /// `ConnectionState.reconnecting(attempt:)` had existed in `ChatKit` since
    /// the seam was written and had been emitted by nobody. Nothing asserted
    /// the `.resumed` leg at all until this test, because
    /// `ScriptedTransport.Script` could not drop a body - so every retry died
    /// at `register` and the channel never got back to `.connected`.
    @Test func aRecoveredChannelIsReportedAsReconnectingThenConnected() async throws {
        let head = HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)])
        let transport = ScriptedTransport(
            // Ten, generously: `resolveAndEmitSelf()` races the channel for
            // this queue, and the channel needs a register, an acknowledge
            // and (Part 1's addition) an initial ping on each side of the
            // drop - two fresh SIDs, three consumers each, plus the one
            // self-status call. Content is ignored by all of them.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 10),
            streams: [
                ScriptedTransport.Script(
                    headers: head,
                    chunks: [messageChunk(aid: 1, text: "before the drop")],
                    dropsAfterChunks: true
                ),
                ScriptedTransport.Script(headers: head, chunks: []),
                // Since task 3 of the reconnect taxonomy a transport
                // failure never gives up on its own, so without this the
                // channel would reopen forever after the recovery above and
                // `waitForChannel()` below would hang. A deliberate terminal
                // status ends it cleanly, once the resume this test is
                // actually about has already happened.
                ScriptedTransport.Script(status: 403, chunks: [])
            ]
        )
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .immediate
        )
        try await backend.connect()
        await backend.waitForChannel()

        let states: [ConnectionState] = await collectEvents(backend).compactMap { event in
            if case let .connectionStateChanged(state) = event {
                state
            } else {
                nil
            }
        }
        // `issue`/`detail` are non-nil now: the drop is `ScriptedTransport.Dropped`,
        // not a `ClassifiedTransportFailure`, so it lands on `ChannelSession`'s
        // generic catch as `.transport(nil)` - `ConnectionIssueMapping` still owes
        // it a `ConnectionIssue`, which is `.unknown("transport")` per that
        // mapping's own test.
        let reconnecting = try #require(
            states.firstIndex(of: .reconnecting(
                attempt: 1,
                issue: .unknown("transport"),
                detail: "the connection failed: transport error"
            ))
        )
        // `.connected` *after* the reconnect, not the one `connect()` emitted
        // before it - that is the whole distinction the `.resumed` leg exists
        // to make.
        #expect(states[reconnecting...].contains(.connected))
    }

    /// Fix round 1, Finding 3 (R18): `channelStopped`'s `.disconnected` now
    /// carries a mapped `issue`, not `nil` - the guard on channel identity
    /// means this body is reached only for a genuine terminal failure, so
    /// `channel.failure` is always non-nil where it emits.
    @Test func aTerminalFailureReachesTheUIWithAMappedIssue() async throws {
        let transport = ScriptedTransport(
            // Five, generously - see `aChannelFailureIsReportedOnTheEventStream`'s
            // own comment for why four real consumers race this queue.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [ScriptedTransport.Script(status: 403, chunks: [])]
        )
        let backend = LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .immediate
        )
        try await backend.connect()
        await backend.waitForChannel()

        let states: [ConnectionState] = await collectEvents(backend).compactMap { event in
            if case let .connectionStateChanged(state) = event {
                state
            } else {
                nil
            }
        }
        guard let disconnected = states.last(where: {
            if case .disconnected = $0 {
                true
            } else {
                false
            }
        }) else {
            Issue.record("no .disconnected state among \(states)")
            return
        }
        // `.unexpectedStatus(403)`'s own description and its mapped issue -
        // 403 is not 429 or any 5xx, so `ConnectionIssueMapping` falls
        // through to `.unknown("status 403")` rather than `.serverError`.
        #expect(disconnected == .disconnected(
            reason: "the channel answered with HTTP 403",
            issue: .unknown("status 403")
        ))
    }

    /// The other half of R18: a deliberate `disconnect()` never reaches
    /// `channelStopped` at all - its identity guard short-circuits because
    /// `disconnect()` nils `channelTask` first - so this must still carry
    /// neither a reason nor an issue.
    @Test func aDeliberateDisconnectStillCarriesNoReasonOrIssue() async throws {
        let transport = ScriptedTransport(
            // Five, generously - see `aChannelFailureIsReportedOnTheEventStream`'s
            // own comment. This backend uses the *default* retry policy
            // (no `retry:` argument below), so a starved race here would be
            // a real, timed backoff rather than an immediate spin - `stop()`
            // still cancels it promptly, but there is no reason to invite it.
            [shell()] + Array(repeating: ScriptedTransport.ok(""), count: 5),
            streams: [
                ScriptedTransport.Script(
                    headers: HTTPHeaders([("X-HTTP-Initial-Response", Self.initialResponse)]),
                    chunks: []
                )
            ]
        )
        let backend = LocalBridgeBackend(cookies: Self.cookies, transport: transport)
        try await backend.connect()
        await backend.disconnect()

        let states: [ConnectionState] = await collectEvents(backend).compactMap { event in
            if case let .connectionStateChanged(state) = event {
                state
            } else {
                nil
            }
        }
        guard let disconnected = states.last(where: {
            if case .disconnected = $0 {
                true
            } else {
                false
            }
        }) else {
            Issue.record("no .disconnected state among \(states)")
            return
        }
        #expect(disconnected == .disconnected(reason: nil, issue: nil))
    }
}
