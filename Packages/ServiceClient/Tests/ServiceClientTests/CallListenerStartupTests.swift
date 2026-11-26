import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing
@testable import ChatService

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallListenerStartupTests {
    @Test func serializedObserverWaitsForAnActualListenerOutcomeAndRetainsLaterFailures() async throws {
        let source = StartupCallSource()
        let runtime = makeRuntime(source)
        await runtime.start()
        let initial = try await runtime.read(.init(waitMilliseconds: 0))
        #expect(initial.isListenerStarting)
        let facade = try makeFacade(runtime)
        let log = StartupCallLog()
        let reader = Task { for await event in facade.events {
            log.events.append(event)
        } }
        try await facade.startListening()
        // An ordered event proves the initial snapshot and directory delivery were consumed.
        let marker = AudioCallEvent.unknown("startup-barrier")
        source.emit(.recipientsChanged([source.peer]))
        try await callEventually {
            try await runtime.read(.init(waitMilliseconds: 0)).recipients == [source.peer]
        }
        source.emit(marker)
        try await callEventually { log.events.contains(marker) }
        #expect(log.listenerStates.isEmpty)
        source.emit(.listenerChanged(isListening: true))
        try await callEventually { log.listenerStates == [true] }
        source.emit(.listenerChanged(isListening: false))
        try await callEventually { log.listenerStates == [true, false] }
        // A new observer must see a real failure even if a directory event followed it.
        source.emit(.recipientsChanged([]))
        try await callEventually { try await runtime.read(.init(waitMilliseconds: 0)).recipients.isEmpty }
        await facade.stop()
        try await facade.startListening()
        try await callEventually { log.listenerStates == [true, false, false] }
        source.emit(.listenerChanged(isListening: true))
        try await callEventually { log.listenerStates == [true, false, false, true] }
        await facade.stop()
        reader.cancel()
        await reader.value
        await runtime.stop()
    }

    @Test func thrownStartupFailureIsPublishedBeforeAnySuccessfulConnection() async throws {
        let source = StartupCallSource(failStart: true)
        let runtime = makeRuntime(source)
        await runtime.start()
        try await callEventually { try await !runtime.read(.init(waitMilliseconds: 0)).isListenerStarting }
        let facade = try makeFacade(runtime)
        let log = StartupCallLog()
        let reader = Task { for await event in facade.events {
            log.events.append(event)
        } }
        try await facade.startListening()
        try await callEventually { log.listenerStates == [false] }
        #expect(try await !runtime.read(.init(waitMilliseconds: 0)).isListening)
        await facade.stop()
        reader.cancel()
        await reader.value
        await runtime.stop()
    }

    private func makeRuntime(_ source: StartupCallSource) -> ServiceCallRuntime {
        ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(),
            principal: .init("owner"), device: .init("device")
        )
    }

    private func makeFacade(_ runtime: ServiceCallRuntime) throws -> ServiceAudioCallService {
        let account = AccountSummary(
            id: .init("account"), selfID: .init("self"), label: "Acme",
            connection: .connected, revision: .init("revision")
        )
        let client = AccountClient(transport: InProcessChatTransport(
            endpoint: StartupCallEndpoint(runtime: runtime),
            context: ServiceSessionContext(
                principalID: .init("owner"), deviceID: .init("device"),
                sessionID: .init("client"), accounts: [account.id]
            )
        ))
        return try ServiceAudioCallService(account: account, client: client)
    }
}

@MainActor
private final class StartupCallLog {
    var events: [AudioCallEvent] = []
    var listenerStates: [Bool] {
        events.compactMap {
            if case let .listenerChanged(listening) = $0 {
                return listening
            }
            return nil
        }
    }
}

private struct StartupCallEndpoint: ServiceEndpoint {
    let runtime: ServiceCallRuntime

    func handle(_ data: Data, context _: ServiceSessionContext) async throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: data)
        let state = try await runtime.read(request.decodePayload(ReadCallState.self))
        return try ServiceCodec.encode(ServiceResponse(
            requestID: request.header.requestID, accountID: request.header.accountID,
            result: .success(ServiceCodec.value(state)), accountRevision: request.header.accountRevision
        ))
    }
}

@MainActor
private final class StartupCallSource: AudioCallService {
    let events: AsyncStream<AudioCallEvent>
    private let sink: AsyncStream<AudioCallEvent>.Continuation
    let failStart: Bool
    let peer = AudioCallRecipient(
        conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
    )

    init(failStart: Bool = false) {
        self.failStart = failStart
        (events, sink) = AsyncStream.makeStream()
    }

    func emit(_ event: AudioCallEvent) {
        sink.yield(event)
    }

    func startListening() async throws {
        if failStart {
            throw ChatError.transport("listener failed")
        }
    }

    func stop() async {}
    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {}
    func accept(callID _: UUID) async throws {}
    func decline(callID _: UUID) async throws {}
    func hangUp(callID _: UUID) async throws {}
    func setMuted(_: Bool, callID _: UUID) async throws {}
}
