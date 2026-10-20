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
        let pause = Task { try await runtime.control(
            .init(action: "pause", sourceID: runtime.identity),
            session: .init("client")
        ) }
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
        _ = try await runtime.control(
            .init(action: "restart", sourceID: runtime.identity),
            session: .init("client")
        )
        try await callEventually { try await runtime.read(.init(waitMilliseconds: 0)).isListening }
        #expect(try await runtime.read(.init(waitMilliseconds: 0)).recipients == [source.peer])
        await runtime.stop()
    }

    @Test func aDeclinedInvitationCannotReappearFromALateSourceCallback() async throws {
        let source = HeldRecoverySource()
        let runtime = ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(),
            principal: .init("owner"), device: .init("device")
        )
        await runtime.start()
        let id = UUID()
        var snapshot = AudioCallSnapshot(
            id: id,
            recipient: source.peer,
            direction: .incoming,
            phase: .incoming
        )
        source.emit(.snapshot(snapshot))
        try await callEventually {
            try await runtime.read(.init(waitMilliseconds: 0)).call?.phase == .incoming
        }
        _ = try await runtime.control(
            .init(action: "decline", callID: id, sourceID: runtime.identity),
            session: .init("client")
        )
        snapshot.phase = .declined
        source.emit(.snapshot(snapshot))
        try await callEventually {
            try await runtime.read(.init(waitMilliseconds: 0)).call?.phase == .declined
        }
        snapshot.phase = .incoming
        source.emit(.snapshot(snapshot))
        source.emit(.listenerChanged(isListening: false))
        try await callEventually { try await !runtime.read(.init(waitMilliseconds: 0)).isListening }
        #expect(try await runtime.read(.init(waitMilliseconds: 0)).call?.phase == .declined)
        await runtime.stop()
    }

    @Test func captureIsSuppressedBeforeWaitingForTheSharedCleanupSlot() async throws {
        let source = HeldRecoverySource()
        let budget = AccountWorkAdmission(limit: 1)
        let occupied = UUID()
        try await budget.acquire(occupied)
        let runtime = ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(), principal: .init("owner"),
            device: .init("device"), cleanupAdmission: budget
        )
        await runtime.start()
        let stopping = Task { await runtime.stop() }
        try await callEventually {
            let queued = await budget.waitingCount
            return source.beganStopping && queued == 1
        }
        #expect(!source.stopped)
        await budget.release(occupied)
        await stopping.value
        #expect(source.stopped)
        #expect(await budget.activeCount == 0)
    }

    @Test func shutdownReleasesAPendingRecoveryAcknowledgement() async throws {
        let source = HeldRecoverySource()
        let runtime = ServiceCallRuntime(
            source: source, reservations: CallDeviceReservations(),
            principal: .init("owner"), device: .init("device")
        )
        await runtime.start()
        let pause = Task { try await runtime.control(
            .init(action: "pause", sourceID: runtime.identity),
            session: .init("client")
        ) }
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
    private var snapshot: AudioCallSnapshot?
    var beganStopping = false
    var stopped = false
    let peer = AudioCallRecipient(conversationID: .init("chat"), memberID: .init("peer"), displayName: "Peer")

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: AudioCallEvent) {
        if case let .snapshot(value) = event {
            snapshot = value
        }
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

    func beginStopping() {
        beganStopping = true
    }

    func stop() async {
        stopped = true
        finishPause()
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {}
    func accept(callID _: UUID) async throws {}
    func decline(callID: UUID) async throws {
        if var snapshot, snapshot.id == callID {
            snapshot.phase = .declined; emit(.snapshot(snapshot))
        }
    }

    func hangUp(callID _: UUID) async throws {}
    func setMuted(_: Bool, callID _: UUID) async throws {}
}
