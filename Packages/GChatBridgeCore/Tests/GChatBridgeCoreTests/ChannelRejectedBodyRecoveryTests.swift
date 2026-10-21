import Foundation
import Testing
@testable import GChatBridgeCore

@Suite(.timeLimit(.minutes(1)))
struct ChannelRejectedBodyRecoveryTests {
    @Test(arguments: [400, 429, 500, 503])
    func rejectedHeadersReconnectWithoutWaitingForTheRejectedBody(status: Int) async throws {
        try await verifyRecovery(status: status, failedInitialPing: false)
    }

    @Test func failedInitialPingReconnectsWithoutReadingTheAbandonedBody() async throws {
        try await verifyRecovery(status: 200, failedInitialPing: true)
    }

    private func verifyRecovery(status: Int, failedInitialPing: Bool) async throws {
        let transport = RejectedBodyTransport(status: status, failedInitialPing: failedInitialPing)
        let cookies = try #require(SessionCookies(cookies: [.init(name: "COMPASS", value: "synthetic")]))
        let observations = RecoveryObservations()
        let session = ChannelSession(
            cookies: cookies, transport: transport, retry: .immediate,
            onLifecycle: { await observations.record($0) }
        )
        let received = Task { () -> [Int] in
            var aids: [Int] = []
            for await array in session.events {
                aids.append(array.aid)
            }
            return aids
        }
        let running = Task { await session.start() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await transport.registrations < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The body is still held here: a completed recovery cannot depend on EOF.
        let registrations = await transport.registrations
        #expect(registrations == 2)
        #expect(await transport.rejectedBodyIsTerminated)
        await transport.releaseRejectedBody()
        if registrations < 2 {
            await session.stop()
        }
        await running.value
        let aids = await received.value
        #expect(aids == [1])
        #expect(await session.failure == .unexpectedStatus(403))
        let lifecycle = await observations.values
        let failure: ChannelFailure = failedInitialPing ? .transport(.timedOut) :
            .unexpectedStatus(status)
        #expect(lifecycle.first == .reconnecting(attempt: 1, failure: failure))
        #expect(lifecycle.filter { $0 == .resumed }.count == 1)
        #expect(await transport.abandonedPings == 0)
    }
}

private actor RecoveryObservations {
    private(set) var values: [ChannelLifecycle] = []
    func record(_ value: ChannelLifecycle) {
        values.append(value)
    }
}

private actor RejectedBodyTransport: HTTPTransport {
    private let status: Int
    private let failedInitialPing: Bool
    private var streams = 0
    private(set) var registrations = 0
    private(set) var abandonedPings = 0
    private var held: AsyncThrowingStream<Data, any Error>.Continuation?

    init(status: Int, failedInitialPing: Bool) {
        self.status = status
        self.failedInitialPing = failedInitialPing
    }

    func send(_ request: HTTPRequest) -> HTTPResponse {
        if request.traceLabel == "register" {
            registrations += 1
        }
        return HTTPResponse(status: 200, headers: .init([]), body: Data())
    }

    func fireAndForget(_ request: HTTPRequest) throws -> HTTPHeaders {
        if streams == 1, failedInitialPing {
            if request.traceLabel == "ping" {
                throw ClassifiedTransportFailure(.timedOut)
            }
            if request.traceLabel == "ping" {
                abandonedPings += 1
            }
        }
        return .init([])
    }

    func stream(_: HTTPRequest) -> HTTPStream {
        streams += 1
        if streams == 1 {
            let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            held = continuation
            return HTTPStream(status: status, headers: headers("abandoned"), body: body)
        }
        if streams == 2 {
            return HTTPStream(status: 200, headers: headers("recovered"), body: AsyncThrowingStream {
                $0.yield(Data("11\n[[1,[\"a\"]]]".utf8))
                $0.finish()
            })
        }
        return HTTPStream(status: 403, headers: .init([]), body: AsyncThrowingStream { $0.finish() })
    }

    var rejectedBodyIsTerminated: Bool {
        guard let held else { return true }
        if case .terminated = held.yield(Data()) {
            return true
        }
        return false
    }

    func releaseRejectedBody() {
        held?.finish()
        held = nil
    }

    private func headers(_ sid: String) -> HTTPHeaders {
        .init([("X-HTTP-Initial-Response", "[[0,[\"c\",\"\(sid)\",\"\",8,12,30000]]]")])
    }
}
