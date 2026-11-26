import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ProjectedLifecycleTests {
    @Test func providerGapDoesNotBlockReplicaAcknowledgementOnItsOwnRefresh() async throws {
        let harness = try await ClientHarness.make()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: harness.backend(harness.first), store: store)
        try await engine.start()
        try await eventually { try store.me() == harness.first.selfID }
        let canonical = try await harness.canonical(harness.first.id)
        let before = try canonical.checkpoint()
        try await harness.providers.gap(harness.first.id)
        var target: UInt64?
        try await eventually {
            target = try canonical.readEvents(after: before, limit: 256).events.first {
                if case .historyLoaded = $0.event {
                    return true
                }; return false
            }?.cursor.sequence
            return target != nil
        }
        let expected = try #require(target)
        let deadline = ContinuousClock.now + .seconds(4)
        var applied = false
        while ContinuousClock.now < deadline {
            if try store.replicaCheckpoint()?.sequence ?? 0 >= expected {
                applied = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applied)
        await engine.stop()
        await harness.service.shutdown()
    }

    @Test func disconnectDuringNegotiationCannotAttachALateSubscription() async throws {
        let transport = HeldNegotiation()
        let backend = ServiceBackend(account: AccountSummary(
            id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Account",
            connection: .idle, revision: ServiceAccountRevision("binding")
        ), transport: transport)
        let connecting = Task { try await backend.connect() }
        try await eventually { await transport.entered }
        await backend.disconnect()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(await transport.subscriptions == 0)
        await backend.disconnect()
    }
}

private actor HeldNegotiation: ServiceEventTransport {
    private(set) var entered = false
    private(set) var subscriptions = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func negotiate(_ version: ServiceAPIVersion) async -> ServiceAPIVersion {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return version
    }

    func release() {
        continuation?.resume(); continuation = nil
    }

    func exchange(_ request: ServiceRequest) -> ServiceResponse {
        ServiceResponse(replyingTo: request, result: .failure(.unsupportedOperation))
    }

    func events(_ request: ServiceRequest) -> AsyncThrowingStream<ServiceEventPage, any Error> {
        subscriptions += 1
        return AsyncThrowingStream { $0.finish() }
    }
}
