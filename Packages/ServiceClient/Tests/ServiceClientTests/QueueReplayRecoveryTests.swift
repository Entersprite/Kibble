import ChatAPI
import ChatKit
import Foundation
import ServiceClient
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct QueueReplayRecoveryTests {
    @Test func queuePressureReplaysEveryCommittedEventWithoutAConnectionWarning() async throws {
        let transport = QueueReplayTransport(holdReplay: true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(
            backend: ServiceBackend(account: transport.account, transport: transport),
            store: store
        )
        let log = QueueAvailabilityLog()
        let states = await engine.clientTransportAvailability()
        let observer = Task { for await value in states {
            await log.append(value)
        } }
        defer { observer.cancel(); Task { await transport.release(); await engine.stop() } }
        try await engine.start()
        try await eventually { try store.replicaCheckpoint()?.sequence == 0 }
        await transport.overflow(count: 24)
        try await eventually { await transport.reading }
        // Hold the journal read so an eventual recovery cannot hide a false warning.
        #expect(await log.values == [true])
        #expect(try store.messages(in: QueueReplayTransport.conversation).isEmpty)
        await transport.release()
        try await eventually {
            try store.messages(in: QueueReplayTransport.conversation).count == 24 &&
                store.replicaCheckpoint()?.sequence == 24
        }
        try await eventually { await transport.subscriptions == 2 }
        #expect(await log.values == [true])
        #expect(await transport.reads == 8)
        await engine.stop()
        observer.cancel(); await observer.value
    }

    @Test func cancelingAHeldReplayCannotPublishAWarningAfterDisconnect() async throws {
        let transport = QueueReplayTransport(holdReplay: true)
        let backend = ServiceBackend(account: transport.account, transport: transport)
        let log = QueueDeliveryLog()
        let deliveries = await backend.useCheckpointedDeliveries(after: nil)
        let observer = Task { for await delivery in deliveries {
            await log.append(delivery)
            if let checkpoint = delivery.checkpoint {
                await backend.acknowledge(checkpoint, applied: true)
            }
        } }
        defer { observer.cancel(); Task { await transport.release(); await backend.disconnect() } }
        try await backend.connect()
        try await eventually { await log.availability == [true] }
        await transport.overflow(count: 1)
        try await eventually { await transport.reading }
        let stopping = Task { await backend.disconnect() }
        try await eventually { await transport.replayCancelled }
        await transport.release()
        await stopping.value
        // The final disconnect event is a FIFO barrier after any stale warning.
        try await eventually { await log.disconnected }
        #expect(await log.availability == [true])
        observer.cancel(); await observer.value
    }

    @Test func aFailedReplayStillReportsTheConnectionAsUnavailable() async throws {
        let transport = QueueReplayTransport(replayFailure: .notAuthorized)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(
            backend: ServiceBackend(account: transport.account, transport: transport),
            store: store
        )
        let log = QueueAvailabilityLog()
        let states = await engine.clientTransportAvailability()
        let observer = Task { for await value in states {
            await log.append(value)
        } }
        defer { observer.cancel(); Task { await engine.stop() } }
        try await engine.start()
        try await eventually { try store.replicaCheckpoint()?.sequence == 0 }
        await transport.overflow(count: 1)
        try await eventually { await log.values.contains(false) }
        #expect(try store.messages(in: QueueReplayTransport.conversation).isEmpty)
        await engine.stop()
        observer.cancel(); await observer.value
    }
}

private actor QueueAvailabilityLog {
    private(set) var values: [Bool] = []
    func append(_ value: Bool) {
        values.append(value)
    }
}

private actor QueueDeliveryLog {
    private(set) var availability: [Bool] = []
    private(set) var disconnected = false
    func append(_ delivery: ChatDelivery) {
        if let available = delivery.clientTransportAvailable {
            availability.append(available)
        }
        if delivery.events.contains(where: {
            if case .connectionStateChanged(.disconnected) = $0 {
                true
            } else {
                false
            }
        }) {
            disconnected = true
        }
    }
}

private actor QueueReplayTransport: ServiceEventTransport {
    static let conversation = Conversation.ID("conversation")
    nonisolated let account = AccountSummary(
        id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Acme",
        connection: .connected, revision: ServiceAccountRevision("binding")
    )
    private let replayFailure: ServiceFailure?
    private var holdReplay: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var ledger: [ServiceEvent] = []
    private var sink: AsyncThrowingStream<ServiceEventPage, any Error>.Continuation?
    private(set) var subscriptions = 0
    private(set) var reads = 0
    private(set) var reading = false
    private(set) var replayCancelled = false

    init(holdReplay: Bool = false, replayFailure: ServiceFailure? = nil) {
        self.holdReplay = holdReplay; self.replayFailure = replayFailure
    }

    func negotiate(_ version: ServiceAPIVersion) -> ServiceAPIVersion {
        version
    }

    func exchange(_ request: ServiceRequest) async throws -> ServiceResponse {
        let value: JSONValue
        switch request.operation {
        case AttachAccountClient.operation:
            value = try ServiceCodec.value(ClientAttachment(
                id: ClientAttachmentID("lease"), expiresAt: Date().addingTimeInterval(60)
            ))
        case DetachAccountClient.operation: value = try ServiceCodec.value(ServiceUnit())
        case ReadEvents.operation:
            reads += 1; reading = true
            if holdReplay {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { waiter = $0 }
                } onCancel: {
                    Task { await self.markReplayCancelled() }
                }
            }
            try Task.checkCancellation()
            if let replayFailure {
                throw replayFailure
            }
            value = try ServiceCodec.value(page(after: request.decodePayload(ReadEvents.self).cursor))
        default: throw ServiceFailure.unsupportedOperation
        }
        return ServiceResponse(replyingTo: request, result: .success(value))
    }

    func events(_ request: ServiceRequest) throws -> AsyncThrowingStream<ServiceEventPage, any Error> {
        subscriptions += 1
        let (stream, sink) = AsyncThrowingStream<ServiceEventPage, any Error>.makeStream()
        self.sink = sink
        if subscriptions == 1 {
            sink.yield(ServiceEventPage(checkpoint: position(0), snapshot: [
                .conversationsChanged([Conversation(id: Self.conversation, kind: .space)]),
                .selfIdentified(Member(id: account.selfID, kind: .human, displayName: "Self"))
            ], events: [], hasMore: false))
        } else if let replayFailure {
            sink.finish(throwing: replayFailure)
        } else {
            try sink.yield(page(after: request.decodePayload(ReadEvents.self).cursor))
        }
        return stream
    }

    func overflow(count: Int) {
        ledger = (1 ... count).map { index in ServiceEvent(
            cursor: position(index), event: .messageReceived(Message(
                id: Message.ID("message-\(index)"), conversationID: Self.conversation,
                threadID: MessageThread.ID("thread"), sender: account.selfID,
                text: "Message \(index)", createdAt: Date(timeIntervalSince1970: Double(index))
            )), isLiveArrival: false
        ) }
        sink?.finish(throwing: ServiceFailure.resynchronizationRequired)
    }

    private func markReplayCancelled() {
        replayCancelled = true
    }

    func release() {
        holdReplay = false; waiter?.resume(); waiter = nil
    }

    private func page(after cursor: ServiceCursor?) -> ServiceEventPage {
        let events = Array(ledger.filter { $0.cursor.sequence > (cursor?.sequence ?? 0) }.prefix(3))
        let last = events.last?.cursor ?? cursor ?? position(0)
        return ServiceEventPage(
            checkpoint: last,
            snapshot: nil,
            events: events,
            hasMore: last.sequence < ledger.count
        )
    }

    private func position(_ sequence: Int) -> ServiceCursor {
        ServiceCursor(accountID: account.id, streamID: ServiceStreamID("stream"), sequence: UInt64(sequence))
    }
}
