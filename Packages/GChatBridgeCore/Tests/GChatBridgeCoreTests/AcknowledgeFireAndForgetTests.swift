import Foundation
import Testing
@testable import GChatBridgeCore

/// Pins the fix for the ~64-second deaf window `--probe=channeltrace` measured
/// against a live account: `ChannelSession.openStream(_:)` calls
/// `acknowledgeAndPingIfPending()` before its own body-read loop, and the old
/// `.acknowledge` arm read `send(requests.acknowledge(...)) {}` -
/// `send(_:)` awaits the transport's *whole* response body. The server held
/// that body open for ~64 seconds, so every registration bought a window with
/// no long poll being read at all, even though its bytes were already sitting
/// in the transport's own buffered stream. See `ChannelAcknowledge.swift` for
/// the full trace and the fix (`transport.fireAndForget(_:)`, which returns at
/// headers and never reads the body).
///
/// `SlowAcknowledgeTransport` below simulates exactly that shape: its
/// `send(_:)` never returns for anything after the first call (the
/// registration), so a regression back to routing the ack through `send(_:)`
/// reproduces the stall - bounded here, rather than hanging the suite, by
/// `startAndWait`, copied from `ChannelSessionFailurePairingTests.swift` for
/// the same reason that file's own header gives for copying it from
/// `ChannelSessionReconnectTests.swift` a duplicate this small is cheaper than
/// a shared type nobody reads, and test scaffolding is exactly that kind of
/// sharing.
struct AcknowledgeFireAndForgetTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func cookies(_ pairs: [(String, String)] = [("COMPASS", "old")]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    /// Starts `body` on a background `Task` and waits for `condition` to
    /// become true, without ever hanging the suite if it does not. Returns
    /// the `Task` so the caller can `stop()` the session and await it. Copied
    /// from `ChannelSessionFailurePairingTests.swift` - see that file's own
    /// doc comment for the full history of why it is shaped this way rather
    /// than racing `running.value` against the poll.
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
        // Ten seconds, matching every other use of this helper: every
        // condition here is satisfied in well under a millisecond once the
        // fix is in place, so this is a hang guard, not a realistic timing
        // budget.
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if await condition() {
                break
            }
            if await doneFlag.isDone {
                await Issue.record("""
                the channel finished on its own before the expected condition was met. \
                Observed: \(observed())
                """)
                break
            }
            if ContinuousClock.now >= deadline {
                await Issue.record("""
                timed out waiting for the expected condition - the acknowledge may be gating the \
                body read/reopen again, the exact regression this test exists to catch. \
                Observed: \(observed())
                """)
                break
            }
            await Task.yield()
        }
        return running
    }

    /// The regression test: even though the acknowledge's underlying request
    /// never completes, the handshake's already-open body is still read and
    /// the reopen that follows `.bodyEnded` still happens.
    ///
    /// `streamCallCount` reaching 2 is the reopen's own `transport.stream(_:)`
    /// call - it can only happen after `.bodyEnded`, which can only happen
    /// after the handshake's body was actually read, which (before the fix)
    /// never happened because `acknowledgeAndPingIfPending()` was stuck
    /// awaiting `send(_:)`'s full response.
    @Test func theAcknowledgeNeverGatesTheBodyReadOrTheReopen() async {
        let transport = SlowAcknowledgeTransport(
            initialResponse: initialResponse,
            handshakeChunks: ["11\n[[1,[\"a\"]]]"]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)

        let running = await startAndWait {
            await session.start()
        } observed: {
            await """
            streamCallCount=\(transport.streamCallCount) \
            sendCallCount=\(transport.sendCallCount) \
            fireAndForgetCallCount=\(transport.fireAndForgetCallCount)
            """
        } until: {
            await transport.streamCallCount >= 2
        }
        await session.stop()
        _ = await running.value

        // The ack and the initial ping are still both sent - fixing the gate
        // must not silently stop sending either. See the reference's own
        // comment on the ack: "I'm not sure what else this could be, but it
        // does seem to be required." The ping is Part 1's addition, sent the
        // identical fire-and-forget way immediately behind the ack, so this
        // count is 2 rather than 1.
        #expect(await transport.fireAndForgetCallCount == 2)
        // Only the registration ever goes through `send(_:)`; a regression
        // back to routing the ack or the ping through it would show up here
        // as 2 or 3.
        #expect(await transport.sendCallCount == 1)
    }
}

/// A transport whose `send(_:)` never returns for anything after the first
/// call, simulating the measured ~64-second server-held acknowledge body -
/// parked forever rather than timed, so the test's own bounded wait (not a
/// race against a magic number) decides pass or fail. `fireAndForget(_:)` is
/// overridden separately, returning immediately with empty headers - the
/// shape `URLSessionTransport.fireAndForget(_:)` actually returns in
/// production, where the head arrives fast and only the discarded body was
/// ever slow.
///
/// A dedicated fake rather than `FakeHTTPTransport` for the same reason
/// `ChannelSessionFailurePairingTests.DualFailureTransport` is one: that
/// fixture has no notion of a call that never completes, and improvising one
/// onto it would be a bigger change than a fake written for exactly this
/// shape.
private actor SlowAcknowledgeTransport: HTTPTransport {
    private(set) var sendCallCount = 0
    private(set) var fireAndForgetCallCount = 0
    private(set) var streamCallCount = 0
    private let initialResponse: String
    private let handshakeChunks: [String]

    init(initialResponse: String, handshakeChunks: [String]) {
        self.initialResponse = initialResponse
        self.handshakeChunks = handshakeChunks
    }

    /// Call 1 is `register`, which must succeed for the handshake - and
    /// therefore the acknowledge this test is actually about - to ever be
    /// reached. Anything after that never returns: if production code ever
    /// regresses to routing the ack through `send(_:)` again, this is what
    /// makes that regression fail the bounded test rather than pass it by
    /// accident.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sendCallCount += 1
        guard sendCallCount == 1 else {
            try await Task.sleep(for: .seconds(86400))
            throw CancellationError()
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    /// The fix's actual call path - returns immediately, the same shape
    /// `URLSessionTransport.fireAndForget(_:)` returns in production.
    func fireAndForget(_ request: HTTPRequest) async throws -> HTTPHeaders {
        fireAndForgetCallCount += 1
        return HTTPHeaders([])
    }

    /// Call 1 is the handshake, carrying a fresh SID and the scripted chunks.
    /// Call 2 is the reopen that follows `.bodyEnded`; it answers with a
    /// deliberately terminal status (403 - not 400, 429 or any 5xx, so it
    /// stays terminal even after the reconnect taxonomy) so the session ends
    /// on its own rather than needing a third script.
    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        streamCallCount += 1
        guard streamCallCount == 1 else {
            return HTTPStream(
                status: 403,
                headers: HTTPHeaders([]),
                body: AsyncThrowingStream { $0.finish() }
            )
        }
        return HTTPStream(
            status: 200,
            headers: HTTPHeaders([("X-HTTP-Initial-Response", initialResponse)]),
            body: AsyncThrowingStream { continuation in
                for chunk in handshakeChunks {
                    continuation.yield(Data(chunk.utf8))
                }
                continuation.finish()
            }
        )
    }
}

/// Set by `startAndWait`'s wrapped `body`, from inside its own task, the
/// instant it returns - see `ChannelSessionFailurePairingTests`'s own copy of
/// this type for why this exists instead of a sibling task awaiting
/// `Task.value`.
private actor CompletionFlag {
    private(set) var isDone = false

    func markDone() {
        isDone = true
    }
}
