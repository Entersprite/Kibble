import Foundation
import Testing
@testable import GChatBridgeCore

/// Answers every POST with an empty 200, and holds the first stream open
/// until the test stops the session, so the channel sits in `.listening`.
private actor OpenChannelTransport: HTTPTransport {
    struct Closed: Error {}

    private(set) var sent: [HTTPRequest] = []
    private var opened = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        sent.append(request)
        guard !opened else { throw Closed() }
        opened = true
        return HTTPStream(
            status: 200,
            headers: HTTPHeaders([("X-HTTP-Initial-Response", #"[[0,["c","S3ss10n","",8,12,30000]]]"#)]),
            body: AsyncThrowingStream { _ in }
        )
    }

    func pings() -> [HTTPRequest] {
        sent.filter { $0.traceLabel == "ping" }
    }
}

/// The ping again, on demand (active-presence spec §4): what it says, and
/// that it goes only on an open channel with that channel's counters.
@Suite(.timeLimit(.minutes(1)))
struct ChannelActivityPingTests {
    private let requests = ChannelRequests(endpoints: ChatEndpoints())

    private func body(_ request: HTTPRequest) -> String {
        String(decoding: request.body ?? Data(), as: UTF8.self)
    }

    private func query(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// `[null,[2,null,2,null,4,true]]`: `INACTIVE`, `FOCUS_STATE_BACKGROUND`,
    /// `HIDDEN`, notifications still on.
    @Test func anInactivePingSaysSo() throws {
        let ping = try #require(requests.ping(sid: "abc", aid: 0, rid: 1, ofs: 0, active: false))
        #expect(body(ping) == "count=1&ofs=0&req0_data=%5Bnull%2C%5B2%2Cnull%2C2%2Cnull%2C4%2Ctrue%5D%5D")
    }

    @Test func anActivePingIsTheInitialOne() throws {
        let initial = try #require(requests.ping(sid: "abc", aid: 0, rid: 1, ofs: 0))
        let active = try #require(requests.ping(sid: "abc", aid: 0, rid: 1, ofs: 0, active: true))
        #expect(body(active) == body(initial))
    }

    @Test func nothingIsSentWithoutAnOpenChannel() async throws {
        let transport = OpenChannelTransport()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b")), transport: transport,
            retry: .immediate
        )
        await session.sendActivityPing(active: true)
        #expect(await transport.sent.isEmpty)
    }

    /// The second ping on the listening channel: same SID, the next RID, the
    /// next stream offset.
    @Test func aListeningChannelSendsItWithItsOwnCounters() async throws {
        let transport = OpenChannelTransport()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b")), transport: transport,
            retry: .immediate
        )
        let running = Task { await session.start() }
        for _ in 0 ..< 1000 where await transport.pings().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let initial = try #require(await transport.pings().first)

        await session.sendActivityPing(active: false)

        let pings = await transport.pings()
        await session.stop()
        running.cancel()
        #expect(pings.count == 2)
        let again = try #require(pings.last)
        #expect(query("SID", of: again.url) == "S3ss10n")
        let initialRID = try #require(query("RID", of: initial.url).flatMap { Int($0) })
        #expect(query("RID", of: again.url) == String(initialRID + 1))
        #expect(body(again).hasPrefix("count=1&ofs=1&"))
        #expect(body(again).hasSuffix("%5B2%2Cnull%2C2%2Cnull%2C4%2Ctrue%5D%5D"))
    }
}
