import Foundation
import Testing
@testable import GChatBridgeCore

/// The driver: the state machine wired to a transport.
///
/// Everything decided here is I/O sequencing and cookie custody — the
/// transitions themselves are `ChannelReducerTests`. The fake transport refuses
/// to improvise, so a session that asks for one request too many ends in a
/// transport failure rather than in a passing test.
///
/// **Every session here is built with `retry: .immediate`.** A transport
/// failure reconnects with `RetryPolicy.default`'s backoff, so on the default
/// policy every test in this file would sleep the full ladder before its
/// stream finished. `.immediate` removes the wait, which is what it was
/// written for.
///
/// **Since task 3 of the reconnect taxonomy, a transport failure never gives
/// up on its own** (see `ChannelFailure.isRecoverable` and
/// `ChannelState.attempt`) - so a fake that simply runs out of script now
/// retries forever instead of failing terminally, which would hang a test
/// that waits for the event stream to finish naturally. Every test below that
/// needs the session to end deterministically scripts a final
/// `terminatingStream()` (a status that still stays terminal - see that
/// helper) rather than relying on the fake's exhaustion, which is what these
/// tests did before task 3.
struct ChannelSessionTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#

    private func cookies(_ pairs: [(String, String)] = [("COMPASS", "old")]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    private func ok(_ setCookies: [String] = []) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders(setCookies.map { ("Set-Cookie", $0) }),
            body: Data()
        )
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

    /// A stream reply that stays terminal even after task 3's changes - 403
    /// is not 400, 429 or any 5xx (see `ChannelFailure.isRecoverable`) - so a
    /// test can end a session deterministically instead of either waiting out
    /// an unbounded reconnect ladder or relying on the fake running dry.
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

    // MARK: - The happy path

    @Test func aSessionDeliversTheArraysItReceives() async {
        let transport = FakeHTTPTransport(
            // register, acknowledge, the initial ping.
            responses: [ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]", "11\n[[2,[\"b\"]]]"]),
                terminatingStream()
            ]
        )
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            endpoints: ChatEndpoints(),
            retry: .immediate
        )
        await session.start()
        let arrays = await collect(session)
        #expect(arrays.map(\.aid) == [1, 2])
    }

    /// The order §3 records, widened by Part 1's ping: register, then the
    /// handshake, then the ack, then the initial ping, then the reopen. The
    /// ack and the ping both have to go **before** the body is read, not
    /// after it — the reference sends them and then falls into the read
    /// loop, and a client that sends either after the poll ends has done so
    /// minutes late.
    ///
    /// Used to assert `paths.count >= 4` with a trailing "ladder of retried
    /// registrations" once the fake ran out, because a transport failure used
    /// to reconnect only up to `RetryPolicy.default.maxAttempts` and running
    /// dry was the trigger. Task 3 of the reconnect taxonomy removed that
    /// ceiling, so a fake that merely runs out now retries forever rather than
    /// stopping - which would hang this test. The second stream below scripts
    /// a deliberate terminal status instead, so the sequence is exactly these
    /// five requests.
    @Test func theRequestSequenceIsRegisterHandshakeAcknowledgePingReopen() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"]), terminatingStream()]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)

        let paths = await transport.sent.map { request -> String in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .percentEncodedQuery ?? ""
            return request.url.lastPathComponent + "?" + query
        }
        #expect(paths[0].hasPrefix("register?"))
        #expect(paths[1].contains("SID=null"))
        #expect(paths[2].contains("RID=rpc") && paths[2].contains("AID=0"))
        // The ping: a POST to the same `events` path, RID the numeric
        // counter (not the literal `rpc`) and no `CI` - see
        // `ChannelRequestsTests.thePingSendsItsQueryParametersInOrderWithNoCI`.
        #expect(paths[3].contains("AID=0") && !paths[3].contains("CI="))
        #expect(await transport.sent[3].method == .post)
        // The reopen carries the watermark from the array that was delivered.
        #expect(paths[4].contains("AID=1"))
        #expect(paths.count == 5)
    }

    @Test func aReopenContinuesDeliveringOnTheSameSession() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"]),
                FakeHTTPTransport.Script(chunks: ["11\n[[2,[\"b\"]]]"]),
                terminatingStream()
            ]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        #expect(await collect(session).map(\.aid) == [1, 2])
    }

    // MARK: - Cookie rotation

    /// `findings.md` §12.3: the `*SIDCC` family rotates on **every** poll cycle
    /// and `COMPASS` grows on `register`, so a frozen header cannot survive one
    /// steady-state reopen. The jar is mandatory rather than an optimisation,
    /// and this is the first component that lives long enough to need it.
    @Test func aRotatedCookieIsAbsorbedAndHandedBackForPersisting() async {
        let transport = FakeHTTPTransport(
            // register (rotates COMPASS), acknowledge, the initial ping.
            responses: [ok(["COMPASS=grown; Path=/"]), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onRotation: { await rotated.record($0) }
        )
        await session.start()
        _ = await collect(session)

        let snapshots = await rotated.snapshots
        #expect(snapshots.count >= 1)
        #expect(snapshots.last?["COMPASS"] == "grown")
    }

    @Test func aRotationOnTheLongPollIsAlsoAbsorbed() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [
                FakeHTTPTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", initialResponse),
                        ("Set-Cookie", "SIDCC=fresh; Path=/")
                    ]),
                    chunks: []
                ),
                terminatingStream()
            ]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onRotation: { await rotated.record($0) }
        )
        await session.start()
        _ = await collect(session)
        #expect(await rotated.snapshots.last?["SIDCC"] == "fresh")
    }

    /// A response that rotates nothing must not write anything back. The
    /// credential store is on disk, and rewriting an unchanged session on every
    /// poll cycle is a write per second forever.
    @Test func anUnchangedCookieSetIsNotWrittenBack() async {
        let transport = FakeHTTPTransport(
            responses: [ok(["COMPASS=old; Path=/"]), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            retry: .immediate,
            onRotation: { await rotated.record($0) }
        )
        await session.start()
        _ = await collect(session)
        #expect(await rotated.snapshots.isEmpty)
    }

    /// Every request carries the *current* jar, not the captured snapshot.
    @Test func requestsCarryTheRotatedCookieRatherThanTheCapturedOne() async {
        let transport = FakeHTTPTransport(
            responses: [ok(["COMPASS=grown; Path=/"]), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)
        let handshake = await transport.sent[1]
        #expect(handshake.headers["Cookie"] == "COMPASS=grown")
    }

    // MARK: - Sharing a credential

    /// `init(credentials:transport:endpoints:)` exists so the channel and the
    /// `/api/` client can share one jar (`findings.md` §12.3) instead of each
    /// holding a copy that goes stale within seconds - see the doc comment on
    /// the initialiser itself. Nothing before this test called it, in sources
    /// or in tests, so nothing pinned that a session built this way actually
    /// authorises its requests with the shared credential rather than some
    /// private state of its own.
    @Test func aSessionBuiltFromSharedCredentialsWritesItsRotationsBackToTheSharedJar() async {
        let credentials = SessionCredentials(cookies())
        let transport = FakeHTTPTransport(
            responses: [ok(["COMPASS=grown; Path=/"]), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let session = ChannelSession(
            credentials: credentials,
            transport: transport,
            endpoints: ChatEndpoints(),
            retry: .immediate
        )
        await session.start()
        _ = await collect(session)

        let sent = await transport.sent
        // The first request, sent before any response has arrived, carries
        // the credential's starting value.
        #expect(sent.first?.headers["Cookie"] == "COMPASS=old")
        // This initialiser takes no `onRotation` (unlike `init(cookies:...)`)
        // because none is needed: the rotation the channel absorbed is
        // visible on the *shared* `credentials` instance itself, the same way
        // a second consumer such as `ProtoAPIClient` would read it.
        #expect(await credentials.header() == "COMPASS=grown")
    }

    /// The other direction of the same property: a rotation another consumer
    /// absorbed into the shared instance - before this channel ever opened -
    /// must be what the channel authorises with, not the value the credential
    /// happened to hold at construction.
    @Test func aSessionBuiltFromSharedCredentialsSeesARotationMadeByAnotherConsumer() async {
        let credentials = SessionCredentials(cookies())
        await credentials.absorb(HTTPHeaders([("Set-Cookie", "COMPASS=grown; Path=/")]))

        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let session = ChannelSession(
            credentials: credentials,
            transport: transport,
            endpoints: ChatEndpoints(),
            retry: .immediate
        )
        await session.start()
        _ = await collect(session)

        let sent = await transport.sent
        #expect(sent.first?.headers["Cookie"] == "COMPASS=grown")
    }

    // MARK: - Stopping

    /// Was HTTP 500. Since task 3 of the reconnect taxonomy every 5xx
    /// recovers rather than stopping (`ChannelFailure.isRecoverable`), so 403
    /// stands in as a status that still ends the session.
    @Test func aNonOKHandshakeEndsTheSessionWithTheReason() async {
        let transport = FakeHTTPTransport(
            responses: [ok()],
            streams: [FakeHTTPTransport.Script(status: 403, chunks: [])]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)
        #expect(await session.failure == .unexpectedStatus(403))
    }

    // Was "a transport failure ends the stream rather than hanging it" -
    // task 3 of the reconnect taxonomy made that literally false. Moved to
    // `ChannelSessionReconnectTests` (which already has the `startAndWait`
    // helper this now needs) to keep this file under swiftlint's 400-line
    // ceiling once fix round 1 added that helper here too.

    @Test func stoppingFinishesTheEventStream() async {
        let transport = FakeHTTPTransport(responses: [ok()], streams: [])
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.stop()
        #expect(await collect(session).isEmpty)
    }

    @Test func startingTwiceDoesNotOpenTwoChannels() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [handshakeStream(chunks: []), terminatingStream()]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        await session.start()
        _ = await collect(session)
        // One handshake, not two. A second channel would show up as a second
        // `SID=null` handshake, which is the thing this test is actually
        // about.
        let handshakes = await transport.sent.filter { request in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .percentEncodedQuery ?? ""
            return query.contains("SID=null")
        }
        #expect(handshakes.count == 1)
    }
}

/// Records rotation callbacks. An actor because the callback crosses isolation.
private actor Rotations {
    private(set) var snapshots: [SessionCookies] = []

    func record(_ snapshot: SessionCookies) {
        snapshots.append(snapshot)
    }
}
