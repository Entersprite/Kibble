import Foundation
import Testing
@testable import GChatBridgeCore

private actor SubscriptionTransport: HTTPTransport {
    struct Dropped: Error {}
    private(set) var sent: [HTTPRequest] = []
    private var streamCount = 0
    private var body: AsyncThrowingStream<Data, any Error>.Continuation?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        return HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        sent.append(request)
        streamCount += 1
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        body = stream.continuation
        let header = "[[0,[\"c\",\"session-\(streamCount)\",\"\",8,12,30000]]]"
        return HTTPStream(
            status: 200, headers: HTTPHeaders([("X-HTTP-Initial-Response", header)]), body: stream.stream
        )
    }

    func drop() {
        body?.finish(throwing: Dropped())
    }

    func subscriptions() -> [HTTPRequest] {
        sent.filter { $0.traceLabel == "groupSubscription" }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GroupSubscriptionTests {
    private func group(_ id: String) -> GroupId {
        var value = GroupId()
        value.dmID.dmID = id
        return value
    }

    private func query(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func decode(_ request: HTTPRequest) throws -> StreamEventsRequest {
        let form = try String(decoding: #require(request.body), as: UTF8.self)
        let url = try #require(URL(string: "https://example.test/?" + form))
        let json = try #require(query("req0_data", of: url))
        return try PBLiteDecoder.decode(StreamEventsRequest.self, fromJSON: Data(json.utf8)).message
    }

    private func waitFor(_ count: Int, on transport: SubscriptionTransport) async throws {
        for _ in 0 ..< 1000 {
            if await transport.subscriptions().count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The channel did not submit its subscription")
    }

    @Test func requestContainsOnlyTheReceiveSubscription() throws {
        let requests = ChannelRequests(endpoints: ChatEndpoints())
        let request = try #require(requests.subscribe(
            group: group("dm"),
            sid: "sid",
            aid: 7,
            rid: 13,
            ofs: 4
        ))
        let event = try decode(request)
        #expect(event.groupSubscriptionEvent.groupIds == [group("dm")])
        #expect(!event.hasPingEvent)
        #expect(query("AID", of: request.url) == "7")
        #expect(query("SID", of: request.url) == "sid")
        #expect(request.method == .post)
        #expect(try String(decoding: #require(request.body), as: UTF8.self).contains("ofs=4"))
    }

    @Test func selectionBeforeConnectReplaysAndSwitchesOnAFreshSID() async throws {
        let transport = SubscriptionTransport()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b")), transport: transport,
            retry: .immediate
        )
        await session.watchGroup(group("first"))
        #expect(await transport.sent.isEmpty)
        let running = Task { await session.start() }
        try await withTaskCancellationHandler {
            try await waitFor(1, on: transport)
            await session.watchGroup(group("selected"))
            try await waitFor(2, on: transport)
            await transport.drop()
            try await waitFor(3, on: transport)
            let requests = await transport.subscriptions()
            #expect(try requests.map { try decode($0).groupSubscriptionEvent.groupIds } == [
                [group("first")], [group("selected")], [group("selected")]
            ])
            #expect(requests.map { query("SID", of: $0.url) } == ["session-1", "session-1", "session-2"])
            #expect(requests.map { String(decoding: $0.body!, as: UTF8.self).components(separatedBy: "&")[1] }
                == ["ofs=1", "ofs=2", "ofs=1"])
            let rids = requests.compactMap { query("RID", of: $0.url).flatMap(Int.init) }
            #expect(rids == rids.sorted())
            await session.stop()
            running.cancel()
        } onCancel: {
            running.cancel()
        }
    }

    @Test func clearedInterestDoesNotReplayAfterReconnect() async throws {
        let transport = SubscriptionTransport()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b")), transport: transport,
            retry: .immediate
        )
        await session.watchGroup(group("first"))
        let running = Task { await session.start() }
        try await waitFor(1, on: transport)
        await session.watchGroup(nil)
        await transport.drop()
        for _ in 0 ..< 1000 {
            if await transport.sent.filter({ $0.traceLabel == "ping" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let pings = await transport.sent.filter { $0.traceLabel == "ping" }
        try #require(pings.count == 2)
        #expect(await session.watchedGroup == nil)
        #expect(await transport.subscriptions().count == 1)
        await session.stop()
        running.cancel()
    }

    @Test func severalClientsReceiveInterestsReplayOnlyTheirCurrentUnion() async throws {
        let transport = SubscriptionTransport()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "SID=a; COMPASS=b")), transport: transport,
            retry: .immediate
        )
        await session.watchGroups([group("first"), group("second"), group("first")])
        let running = Task { await session.start() }
        try await waitFor(2, on: transport)
        await session.watchGroups([group("first"), group("second")])
        #expect(await transport.subscriptions().count == 2)
        await session.watchGroups([group("second")])
        try await waitFor(3, on: transport)
        await transport.drop()
        try await waitFor(4, on: transport)
        let requests = await transport.subscriptions()
        #expect(try requests.map { try decode($0).groupSubscriptionEvent.groupIds } == [
            [group("first")], [group("second")], [group("second")], [group("second")]
        ])
        #expect(requests.map { query("SID", of: $0.url) } == [
            "session-1",
            "session-1",
            "session-1",
            "session-2"
        ])
        await session.stop()
        running.cancel()
    }
}
