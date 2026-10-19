import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TransportRecoveryTests {
    @Test func emptyReplayRecoversClientTransportWithoutClearingProviderFailure() async throws {
        let transport = RecoveringTransport()
        let account = AccountSummary(
            id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Account",
            connection: .idle, revision: ServiceAccountRevision("binding")
        )
        let store = try ChatStore.inMemory()
        _ = try store.applyCheckpointed([], checkpoint: transport.position.replicaCheckpoint)
        let engine = SyncEngine(backend: ServiceBackend(account: account, transport: transport), store: store)
        let availability = AvailabilityLog()
        let states = await engine.clientTransportAvailability()
        let observing = Task { for await state in states {
            await availability.append(state)
        } }
        try await engine.start()
        try await eventually { await availability.values.last == false }
        let providerFailure = ChatError.unknown("Provider problem")
        let providerConnection = ConnectionState.disconnected(reason: "Provider stopped", issue: nil)
        try store.apply([.setLastError(providerFailure), .setConnectionState(providerConnection)])
        await transport.recover()
        try await eventually { await availability.values == [true, false, true] }
        #expect(try store.lastError() == providerFailure)
        #expect(try store.connectionState() == providerConnection)
        #expect(try store.replicaCheckpoint() == transport.position.replicaCheckpoint)
        observing.cancel()
        await observing.value
        await engine.stop()
    }
}

private actor AvailabilityLog {
    private(set) var values: [Bool] = []
    func append(_ value: Bool) {
        values.append(value)
    }
}

private actor RecoveringTransport: ServiceEventTransport {
    nonisolated let position = ServiceCursor(
        accountID: ConnectedAccountID("account"), streamID: ServiceStreamID("stream"), sequence: 0
    )
    private var attempts = 0
    private var recovered = false
    private var sink: AsyncThrowingStream<ServiceEventPage, any Error>.Continuation?

    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func exchange(_ request: ServiceRequest) -> ServiceResponse {
        ServiceResponse(replyingTo: request, result: .failure(.unsupportedOperation))
    }

    func events(_ request: ServiceRequest) -> AsyncThrowingStream<ServiceEventPage, any Error> {
        attempts += 1
        let (stream, sink) = AsyncThrowingStream<ServiceEventPage, any Error>.makeStream()
        if attempts == 1 {
            sink.finish(throwing: ServiceFailure.overloaded)
        } else {
            self.sink = sink
            if recovered {
                yieldRecovery()
            }
        }
        return stream
    }

    func recover() {
        recovered = true
        yieldRecovery()
    }

    private func yieldRecovery() {
        sink?.yield(ServiceEventPage(checkpoint: position, snapshot: nil, events: [], hasMore: false))
    }
}
