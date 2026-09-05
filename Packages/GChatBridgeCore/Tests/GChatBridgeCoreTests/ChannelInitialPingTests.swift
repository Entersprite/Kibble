import Foundation
import Testing
@testable import GChatBridgeCore

/// Part 1's ping, at the driver level. `ChannelRequestsTests` already pins
/// the request's own bytes exactly; `AcknowledgeFireAndForgetTests` already
/// pins that it (like the acknowledge) never gates the body read. This file
/// is what is left: that the driver actually sends it, in the right order,
/// with the counters `findings.md` §12.4 never isolated behaving the way
/// `ChannelSession`'s own doc comments on `requestIdentifier`/
/// `streamEventOfs` describe.
struct ChannelInitialPingTests {
    private let initialResponse = #"[[0,["c","S3ss10n","",8,12,30000]]]"#
    private let secondSID = #"[[0,["c","0therS3ss","",8,12,30000]]]"#

    private func cookies(_ pairs: [(String, String)] = [("COMPASS", "old")]) -> SessionCookies {
        SessionCookies(cookies: pairs.map { SessionCookies.Cookie(name: $0.0, value: $0.1) })!
    }

    private func ok() -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    private func handshakeStream(
        sid: String,
        chunks: [String],
        dropsAfterChunks: Bool = false
    ) -> FakeHTTPTransport.Script {
        FakeHTTPTransport.Script(
            headers: HTTPHeaders([("X-HTTP-Initial-Response", sid)]),
            chunks: chunks,
            dropsAfterChunks: dropsAfterChunks
        )
    }

    /// 403 is not 400, 429 or any 5xx (`ChannelFailure.isRecoverable`), so a
    /// stream answering with it ends the session deterministically rather
    /// than reconnecting - the same helper `ChannelSessionTests` uses.
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

    private func queryItem(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    @Test func thePingIsSentRightAfterTheAcknowledgeForAFreshSID() async throws {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [handshakeStream(sid: initialResponse, chunks: []), terminatingStream()]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)

        let labels = await transport.sent.map { $0.traceLabel ?? "unlabeled" }
        let ackIndex = try #require(labels.firstIndex(of: "acknowledge"))
        #expect(labels.indices.contains(ackIndex + 1))
        if labels.indices.contains(ackIndex + 1) {
            #expect(labels[ackIndex + 1] == "ping")
        }
    }

    @Test func thePingIsAPostFormEncodedRequestCarryingTheAidTheAckAlsoCarries() async throws {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok()],
            streams: [handshakeStream(sid: initialResponse, chunks: []), terminatingStream()]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)

        let sent = await transport.sent
        let ping = try #require(sent.first { $0.traceLabel == "ping" })
        #expect(ping.method == .post)
        #expect(ping.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(queryItem("AID", of: ping.url) == "0")
        #expect(queryItem("SID", of: ping.url) == "S3ss10n")
    }

    /// The reference's own `self._rid` and `self._ofs` (`channel.py:326,336`):
    /// `RID` is shared with the handshake and never resets, so it keeps
    /// climbing across a reconnect's fresh SID; `ofs` resets to 0 right
    /// before every ping, since that effect only ever fires at a fresh SID.
    /// Two fresh SIDs (this session's initial one, and the one minted after
    /// a dropped-socket recovery) prove the two counters are tracked
    /// separately rather than one being derived from the other: `RID`
    /// differs between the two pings while `ofs` does not.
    @Test func ridKeepsClimbingWhileOfsResetsAcrossTwoFreshSIDs() async {
        let transport = FakeHTTPTransport(
            responses: [ok(), ok(), ok(), ok(), ok(), ok()],
            streams: [
                handshakeStream(sid: initialResponse, chunks: [], dropsAfterChunks: true),
                handshakeStream(sid: secondSID, chunks: []),
                terminatingStream()
            ]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport, retry: .immediate)
        await session.start()
        _ = await collect(session)

        let pings = await transport.sent.filter { $0.traceLabel == "ping" }
        #expect(pings.count == 2)
        guard pings.count == 2 else { return }

        let rids = pings.compactMap { queryItem("RID", of: $0.url) }
        #expect(rids.count == 2)
        #expect(rids[0] != rids[1])
        for ping in pings {
            let body = String(decoding: ping.body ?? Data(), as: UTF8.self)
            #expect(body.contains("ofs=0"))
        }
    }
}
