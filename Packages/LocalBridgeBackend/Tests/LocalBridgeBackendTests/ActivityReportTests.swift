import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Answers the shell, `get_self_user_status`, `heartbeat` and the two
/// availability calls; the channel never opens.
private actor ActivityTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Refused: Error {}

    private let selfStatus: UserStatus
    private let refusesHeartbeat: Bool
    private(set) var sent: [HTTPRequest] = []

    init(selfStatus: UserStatus = UserStatus(), refusesHeartbeat: Bool = false) {
        self.selfStatus = selfStatus
        self.refusesHeartbeat = refusesHeartbeat
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        let path = request.url.path
        if path.contains("/mole/world") {
            return ok(Data(LocalBridgeBackendTests.shell(app: "DynamiteWebUi").utf8))
        }
        if path.contains("/api/get_self_user_status") {
            var response = GetSelfUserStatusResponse()
            response.userStatus = selfStatus
            response.userStatus.userID.id = "u-me"
            return try ok(response.serializedBytes())
        }
        if path.contains("/api/heartbeat"), refusesHeartbeat {
            throw Refused()
        }
        if path.contains("/api/set_presence_shared") {
            var response = SetPresenceSharedResponse()
            response.userRevision.timestamp = 1
            return try ok(response.serializedBytes())
        }
        if path.contains("/api/set_dnd_duration") {
            var response = SetDndDurationResponse()
            response.userRevision.timestamp = 1
            return try ok(response.serializedBytes())
        }
        return ok(Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }

    /// Every `heartbeat` sent, decoded: `true` for active.
    func heartbeats() throws -> [Bool] {
        try sent.filter { $0.url.path.contains("/api/heartbeat") }.map { request in
            try HeartbeatRequest(serializedBytes: request.body ?? Data()).presenceUpdateRequest
                .userState == .active
        }
    }

    private func ok(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: HTTPHeaders([]), body: body)
    }
}

/// Keeping you active while the device is in use (active-presence spec §3).
@Suite(.timeLimit(.minutes(1)))
struct ActivityReportTests {
    private static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!
    private static let tick = Duration.milliseconds(50)

    private func backend(_ transport: ActivityTransport, interval: Duration = tick) -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .default,
            presencePollInterval: interval
        )
    }

    /// Bounded: a red test fails rather than hangs (`CLAUDE.md`, Testing).
    private func waitFor(_ transport: ActivityTransport, _ done: ([Bool]) -> Bool) async throws -> [Bool] {
        for _ in 0 ..< 400 {
            let beats = try await transport.heartbeats()
            if done(beats) {
                return beats
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await transport.heartbeats()
    }

    private func connected(_ transport: ActivityTransport, interval: Duration = tick) async throws
        -> LocalBridgeBackend {
        let backend = backend(transport, interval: interval)
        try await backend.connect()
        // `resolveAndEmitSelf` runs behind `connect()`; let it land.
        try await Task.sleep(for: .milliseconds(150))
        return backend
    }

    @Test func inUseReportsActiveAtOnceAndAgainEachInterval() async throws {
        let transport = ActivityTransport()
        let backend = try await connected(transport)
        try await backend.send(.reportActivity(active: true))
        let beats = try await waitFor(transport) { $0.count >= 3 }
        #expect(beats.count >= 3)
        #expect(!beats.contains(false))
        await backend.disconnect()
    }

    /// Away now, not at Google's timeout, and nothing after.
    @Test func notInUseReportsInactiveOnceAndStops() async throws {
        let transport = ActivityTransport()
        let backend = try await connected(transport)
        try await backend.send(.reportActivity(active: true))
        _ = try await waitFor(transport) { !$0.isEmpty }

        try await backend.send(.reportActivity(active: false))
        let atStop = try await waitFor(transport) { $0.last == false }
        try await Task.sleep(for: Self.tick * 4)

        #expect(atStop.last == false)
        #expect(try await transport.heartbeats() == atStop)
        await backend.disconnect()
    }

    /// The app reports before the session is up; the session starts it.
    @Test func aReportBeforeConnectStartsWithTheSession() async throws {
        let transport = ActivityTransport()
        let backend = backend(transport)
        try await backend.send(.reportActivity(active: true))
        #expect(try await transport.heartbeats().isEmpty)

        try await backend.connect()

        #expect(try await waitFor(transport) { !$0.isEmpty }.first == true)
        await backend.disconnect()
    }

    @Test func disconnectStopsIt() async throws {
        let transport = ActivityTransport()
        let backend = try await connected(transport)
        try await backend.send(.reportActivity(active: true))
        _ = try await waitFor(transport) { !$0.isEmpty }

        await backend.disconnect()
        let atDisconnect = try await transport.heartbeats()
        try await Task.sleep(for: Self.tick * 4)

        #expect(try await transport.heartbeats() == atDisconnect)
    }

    /// The report outlives the session it was made in: a stopped channel or a
    /// sign-in again does not need the app to say it twice.
    @Test func aReconnectResumesWithoutBeingToldAgain() async throws {
        let transport = ActivityTransport()
        let backend = try await connected(transport)
        try await backend.send(.reportActivity(active: true))
        _ = try await waitFor(transport) { !$0.isEmpty }
        await backend.disconnect()
        let atDisconnect = try await transport.heartbeats().count

        try await backend.connect()

        #expect(try await waitFor(transport) { $0.count > atDisconnect }.count > atDisconnect)
        await backend.disconnect()
    }

    /// Your setting wins: Away sends nothing active.
    @Test func awayReportsNothing() async throws {
        var away = UserStatus()
        away.presenceShared = false
        let transport = ActivityTransport(selfStatus: away)
        let backend = try await connected(transport)
        try await backend.send(.reportActivity(active: true))
        try await Task.sleep(for: Self.tick * 4)
        #expect(try await transport.heartbeats().isEmpty)
        await backend.disconnect()
    }

    /// Back to Automatic shows green at once, not at the next tick.
    @Test func automaticAfterAwayReportsAtOnce() async throws {
        var away = UserStatus()
        away.presenceShared = false
        let transport = ActivityTransport(selfStatus: away)
        let backend = try await connected(transport, interval: .seconds(60))
        try await backend.send(.reportActivity(active: true))
        #expect(try await transport.heartbeats().isEmpty)

        try await backend.send(.setAvailability(.automatic))

        #expect(try await transport.heartbeats() == [true])
        await backend.disconnect()
    }

    /// A hint repeated every two minutes: a refusal is dropped, not reported.
    @Test func aRefusedHeartbeatReportsNothing() async throws {
        let transport = ActivityTransport(refusesHeartbeat: true)
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        let mark = await log.settle().count
        try await backend.send(.reportActivity(active: true))
        let events = await log.settle(since: mark)
        #expect(!events.contains {
            if case .backendError = $0 {
                true
            } else {
                false
            }
        })
        await backend.disconnect()
    }
}
