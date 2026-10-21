import Foundation
import Testing
@testable import GChatBridgeCore

@Suite(.timeLimit(.minutes(1)))
struct ChannelServerControlTests {
    private let header = #"[[0,["c","fixture","",8,12,30000]]]"#

    @Test func closeRetiresTheSessionAfterDeliveringOnlyItsPrecedingArrays() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, frame(#"[[1,["before"]],[2,["close"]],[3,["after"]]]"#))
        #expect(effects == [
            .deliver([.init(aid: 1, data: .array([.string("before")]))]),
            .reconnect(attempt: 1, failure: .serverClosed)
        ])
        #expect(state.phase == .reconnecting(attempt: 1))
        #expect(state.highestProcessedAid == 1)
    }

    @Test func stopRemainsTerminalAndDoesNotEraseItIntoARecoverableClose() {
        var state = connected()
        #expect(ChannelReducer.reduce(&state, frame(#"[[1,["stop"]]]"#))
            == [.report(.serverStopped), .finished])
        #expect(state.phase == .failed(.serverStopped))
        #expect(ChannelReducer.reduce(&state, .retry).isEmpty)
    }

    @Test func wordsInsideMessageDataAreNeverControlCommands() {
        var state = connected()
        let effects = ChannelReducer.reduce(&state, frame(#"[[1,[["close"]]],[2,["stop","extra"]]]"#))
        #expect(state.phase == .listening(sid: "fixture"))
        #expect(effects.count == 1)
        #expect(state.highestProcessedAid == 2)
    }

    @Test(arguments: [false, true])
    func oneBackchannelDeliversAndACloseDoesNotWaitForEOF(serverCloses: Bool) async throws {
        let transport = SingleBackchannelTransport(serverCloses: serverCloses)
        let observations = ControlObservations()
        let session = try ChannelSession(
            cookies: #require(SessionCookies(header: "COMPASS=fixture")),
            transport: transport,
            retry: .immediate,
            onLifecycle: { await observations.lifecycle($0) }
        )
        let consumer = Task { for await array in session.events {
            await observations.receive(array.aid)
        } }
        let running = Task { await session.start() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await observations.aids.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await observations.aids == [1])
        #expect(await transport.redundantReceivers == 0)
        if serverCloses {
            #expect(await transport.registrations == 2)
            #expect(await transport.firstBodyTerminated)
            #expect(await observations.events.first == .reconnecting(attempt: 1, failure: .serverClosed))
        }
        await session.stop(); await transport.release()
        await running.value; await consumer.value
    }

    private func connected() -> ChannelState {
        var state = ChannelState()
        _ = ChannelReducer.reduce(&state, .connect)
        _ = ChannelReducer.reduce(&state, .registered)
        _ = ChannelReducer.reduce(&state, .streamOpened(status: 200, initialResponse: header))
        return state
    }

    private func frame(_ payload: String) -> ChannelInput {
        .body(Data("\(payload.utf16.count)\n\(payload)".utf8))
    }
}

private actor ControlObservations {
    private(set) var aids: [Int] = []
    private(set) var events: [ChannelLifecycle] = []
    func receive(_ aid: Int) {
        aids.append(aid)
    }

    func lifecycle(_ event: ChannelLifecycle) {
        events.append(event)
    }
}

private actor SingleBackchannelTransport: HTTPTransport {
    let serverCloses: Bool
    private(set) var registrations = 0
    private(set) var redundantReceivers = 0
    private var first: AsyncThrowingStream<Data, any Error>.Continuation?
    private var streamCount = 0

    init(serverCloses: Bool) {
        self.serverCloses = serverCloses
    }

    func send(_ request: HTTPRequest) -> HTTPResponse {
        if request.traceLabel == "register" {
            registrations += 1
        }
        return .init(status: 200, headers: .init([]), body: Data())
    }

    func fireAndForget(_ request: HTTPRequest) -> HTTPHeaders {
        if request.method == .get {
            redundantReceivers += 1
            first?.yield(frame(#"[[2,["close"]]]"#))
        } else if !serverCloses, redundantReceivers == 0, request.traceLabel == "ping" {
            first?.yield(frame(#"[[1,["message"]]]"#))
        }
        return .init([])
    }

    func stream(_ request: HTTPRequest) -> HTTPStream {
        streamCount += 1
        if streamCount > 2 {
            return .init(status: 403, headers: .init([]), body: .init { $0.finish() })
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        if streamCount == 1 {
            first = continuation
            if serverCloses {
                continuation.yield(frame(#"[[1,["close"]]]"#))
            }
        } else {
            continuation.yield(frame(#"[[1,["message"]]]"#)); continuation.finish()
        }
        let headers = HTTPHeaders([(
            "X-HTTP-Initial-Response",
            "[[0,[\"c\",\"fixture-\(streamCount)\",\"\",8,12,30000]]]"
        )])
        return .init(status: 200, headers: headers, body: body)
    }

    var firstBodyTerminated: Bool {
        guard let first else { return false }
        if case .terminated = first.yield(Data()) {
            return true
        }
        return false
    }

    func release() {
        first?.finish()
    }

    private func frame(_ text: String) -> Data {
        Data("\(text.utf16.count)\n\(text)".utf8)
    }
}
