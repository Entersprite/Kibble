import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallRecoveryTests {
    @Test func recoveryPausesOnlyItsAccountAndReattachesThroughTheAPI() async throws {
        let harness = try await CallHarness.make()
        let first = harness.accounts[0]
        let second = harness.accounts[1]
        let summary = try #require(try await harness.client().accounts().first { $0.id == first.id })
        let facade = try ServiceAudioCallService(account: summary, client: harness.client())
        try await facade.startListening()
        try await facade.prepareRecovery()
        let paused = try await harness.read(first)
        #expect(!paused.isListening)
        #expect(paused.recipients.isEmpty)
        #expect(try await harness.read(second).isListening)
        let source = try #require(await harness.providers.source(first.id, device: .init("one")))
        let peer = try #require(try await harness.read(second).recipients.first)
        #expect(source.receiveIncoming(from: peer) == nil)
        try await facade.finishRecovery()
        try await facade.startListening()
        try await callEventually { try await harness.read(first).isListening }
        #expect(try await harness.read(first).recipients.count == 1)
        await facade.stop()
        await harness.service.shutdown()
    }

    @Test func pauseAcknowledgesOnlyAfterTheSourceBarrierAndDropsOldCallbacks() async throws {
        let source = HeldRecoverySource()
        let runtime = ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(),
            principal: .init("owner"), device: .init("device")
        )
        await runtime.start()
        try await callEventually { try await runtime.read(.init(waitMilliseconds: 0)).isListening }
        let pause = Task { try await runtime.control(.init(action: "pause"), session: .init("client")) }
        try await callEventually { source.barrier != nil }
        #expect(await runtime.controlling)
        source.emit(.listenerChanged(isListening: true))
        source.emit(.recipientsChanged([source.peer]))
        source.emit(.snapshot(.init(
            id: UUID(), recipient: source.peer, direction: .incoming, phase: .incoming
        )))
        source.finishPause()
        let state = try await pause.value
        #expect(!state.isListening)
        #expect(state.recipients.isEmpty)
        #expect(state.call == nil)
        _ = try await runtime.control(.init(action: "restart"), session: .init("client"))
        try await callEventually { try await runtime.read(.init(waitMilliseconds: 0)).isListening }
        #expect(try await runtime.read(.init(waitMilliseconds: 0)).recipients == [source.peer])
        await runtime.stop()
    }

    @Test func shutdownReleasesAPendingRecoveryAcknowledgement() async throws {
        let source = HeldRecoverySource()
        let runtime = ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(),
            principal: .init("owner"), device: .init("device")
        )
        await runtime.start()
        let pause = Task { try await runtime.control(.init(action: "pause"), session: .init("client")) }
        try await callEventually { source.barrier != nil }
        await runtime.stop()
        await #expect(throws: (any Error).self) { try await pause.value }
    }
}

@MainActor
private final class HeldRecoverySource: AudioCallQuiescing {
    let events: AsyncStream<AudioCallEvent>
    private let continuation: AsyncStream<AudioCallEvent>.Continuation
    var barrier: UUID?
    let peer = AudioCallRecipient(conversationID: .init("chat"), memberID: .init("peer"), displayName: "Peer")

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: AudioCallEvent) {
        continuation.yield(event)
    }

    func startListening() async throws {
        emit(.recipientsChanged([peer])); emit(.listenerChanged(isListening: true))
    }

    func pauseForRecovery(barrier: UUID) async throws {
        self.barrier = barrier
    }

    func finishPause() {
        if let barrier {
            emit(.listenerBarrier(barrier))
        }
    }

    func stop() async {
        finishPause()
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {}
    func accept(callID _: UUID) async throws {}
    func decline(callID _: UUID) async throws {}
    func hangUp(callID _: UUID) async throws {}
    func setMuted(_: Bool, callID _: UUID) async throws {}
}
