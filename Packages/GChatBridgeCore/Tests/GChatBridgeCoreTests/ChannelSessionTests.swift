import Foundation
import Testing
@testable import GChatBridgeCore

/// The driver: the state machine wired to a transport.
///
/// Everything decided here is I/O sequencing and cookie custody — the
/// transitions themselves are `ChannelReducerTests`. The fake transport refuses
/// to improvise, so a session that asks for one request too many ends in a
/// transport failure rather than in a passing test.
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

    private func handshakeStream(chunks: [String]) -> FakeHTTPTransport.Script {
        FakeHTTPTransport.Script(
            headers: HTTPHeaders([("X-HTTP-Initial-Response", initialResponse)]),
            chunks: chunks
        )
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
            responses: [ok(), ok()],
            streams: [handshakeStream(chunks: ["11\n[[1,[\"a\"]]]", "11\n[[2,[\"b\"]]]"])]
        )
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            endpoints: ChatEndpoints()
        )
        await session.start()
        let arrays = await collect(session)
        #expect(arrays.map(\.aid) == [1, 2])
    }

    /// The order §3 records: register, then the handshake, then the ack, then
    /// the reopen. The ack has to go **before** the body is read, not after it
    /// — the reference sends it and then falls into the read loop, and a client
    /// that acks after the poll ends has acked minutes late.
    @Test func theRequestSequenceIsRegisterHandshakeAcknowledgeReopen() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok()],
            streams: [handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"])]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.start()
        _ = await collect(session)

        let paths = await transport.sent.map { request -> String in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .percentEncodedQuery ?? ""
            return request.url.lastPathComponent + "?" + query
        }
        #expect(paths.count == 4)
        #expect(paths[0].hasPrefix("register?"))
        #expect(paths[1].contains("SID=null"))
        #expect(paths[2].contains("RID=rpc") && paths[2].contains("AID=0"))
        // The reopen carries the watermark from the array that was delivered.
        #expect(paths[3].contains("AID=1"))
    }

    @Test func aReopenContinuesDeliveringOnTheSameSession() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok()],
            streams: [
                handshakeStream(chunks: ["11\n[[1,[\"a\"]]]"]),
                FakeHTTPTransport.Script(chunks: ["11\n[[2,[\"b\"]]]"])
            ]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
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
            responses: [ok(["COMPASS=grown; Path=/"]), ok()],
            streams: [handshakeStream(chunks: [])]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
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
            responses: [ok(), ok()],
            streams: [
                FakeHTTPTransport.Script(
                    headers: HTTPHeaders([
                        ("X-HTTP-Initial-Response", initialResponse),
                        ("Set-Cookie", "SIDCC=fresh; Path=/")
                    ]),
                    chunks: []
                )
            ]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
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
            responses: [ok(["COMPASS=old; Path=/"]), ok()],
            streams: [handshakeStream(chunks: [])]
        )
        let rotated = Rotations()
        let session = ChannelSession(
            cookies: cookies(),
            transport: transport,
            onRotation: { await rotated.record($0) }
        )
        await session.start()
        _ = await collect(session)
        #expect(await rotated.snapshots.isEmpty)
    }

    /// Every request carries the *current* jar, not the captured snapshot.
    @Test func requestsCarryTheRotatedCookieRatherThanTheCapturedOne() async {
        let transport = FakeHTTPTransport(
            responses: [ok(["COMPASS=grown; Path=/"]), ok()],
            streams: [handshakeStream(chunks: [])]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.start()
        _ = await collect(session)
        let handshake = await transport.sent[1]
        #expect(handshake.headers["Cookie"] == "COMPASS=grown")
    }

    // MARK: - Stopping

    @Test func aNonOKHandshakeEndsTheSessionWithTheReason() async {
        let transport = FakeHTTPTransport(
            responses: [ok()],
            streams: [FakeHTTPTransport.Script(status: 500, chunks: [])]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.start()
        _ = await collect(session)
        #expect(await session.failure == .unexpectedStatus(500))
    }

    /// The fake refuses to improvise, so running out of scripted responses is a
    /// transport failure - which is exactly what a socket closing looks like.
    @Test func aTransportFailureEndsTheStreamRatherThanHangingIt() async {
        let transport = FakeHTTPTransport(responses: [], streams: [])
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.start()
        _ = await collect(session)
        #expect(await session.failure != nil)
    }

    @Test func stoppingFinishesTheEventStream() async {
        let transport = FakeHTTPTransport(responses: [ok()], streams: [])
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.stop()
        #expect(await collect(session).isEmpty)
    }

    @Test func startingTwiceDoesNotOpenTwoChannels() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok()],
            streams: [handshakeStream(chunks: [])]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
        await session.start()
        await session.start()
        _ = await collect(session)
        // Four requests, not eight: register, handshake, ack, and the reopen
        // that exhausts the fake.
        #expect(await transport.sent.count <= 4)
    }
}

/// Records rotation callbacks. An actor because the callback crosses isolation.
private actor Rotations {
    private(set) var snapshots: [SessionCookies] = []

    func record(_ snapshot: SessionCookies) {
        snapshots.append(snapshot)
    }
}
