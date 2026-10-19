import ChatAPI
import ChatKit
import Foundation

/// One client/account adapter. Its lifecycle changes subscriptions, never providers.
public actor ServiceBackend: ProjectedChatBackend {
    public nonisolated let capabilities: Capabilities
    public nonisolated let events: AsyncStream<ChatEvent>
    let transport: any ServiceEventTransport
    let accountID: ConnectedAccountID
    let accountRevision: ServiceAccountRevision?
    private let eventSink: AsyncStream<ChatEvent>.Continuation
    private var deliverySink: AsyncStream<ChatDelivery>.Continuation?
    var checkpointed = false
    var resynchronization = UUID()
    var projectionWaiters: [UUID: ProjectionWaiter] = [:]
    var connectionGeneration = UUID()
    var connecting = false
    var cursor: ServiceCursor?
    var consumer: Task<Void, Never>?
    private var acknowledgement: PendingAcknowledgement?

    public init(account: AccountSummary, transport: any ServiceEventTransport) {
        accountID = account.id
        accountRevision = account.revision
        self.transport = transport
        var capabilities = account.capabilities
        // Binary operations become available only with the separate transfer port.
        capabilities.canFetchAttachments = false
        capabilities.canDownloadFiles = false
        capabilities.canFetchCustomEmoji = false
        capabilities.canFetchRemoteImages = false
        capabilities.canSendAttachments = false
        self.capabilities = capabilities
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    public func useCheckpointedDeliveries(after checkpoint: ReplicaCheckpoint?) -> AsyncStream<ChatDelivery> {
        checkpointed = true
        cursor = checkpoint.map(ServiceCursor.init)
        deliverySink?.finish()
        let (stream, sink) = AsyncStream<ChatDelivery>.makeStream(bufferingPolicy: .bufferingOldest(1))
        deliverySink = sink
        return stream
    }

    public func acknowledge(_ checkpoint: ReplicaCheckpoint, applied: Bool) {
        guard let pending = acknowledgement, pending.checkpoint == checkpoint else { return }
        acknowledgement = nil
        pending.continuation.resume(returning: applied)
    }

    public func connect() async throws {
        guard accountRevision != nil else { throw ServiceFailure.invalidResponse }
        guard consumer == nil, !connecting else { return }
        let generation = UUID()
        connectionGeneration = generation
        connecting = true
        defer {
            if generation == connectionGeneration {
                connecting = false
            }
        }
        _ = try await transport.negotiate(.current)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        consumer = Task { [weak self] in await self?.consume(generation: generation) }
    }

    public func disconnect() async {
        let generation = UUID()
        connectionGeneration = generation
        connecting = false
        let task = consumer
        consumer = nil
        task?.cancel()
        cancelAcknowledgement()
        failProjectionWaiters(CancellationError())
        await task?.value
        guard generation == connectionGeneration else { return }
        emitTransient(.connectionStateChanged(.disconnected(reason: nil, issue: nil)))
    }

    public func call<Payload: ServiceRequestPayload>(_ payload: Payload) async throws -> Payload.Response {
        guard let accountRevision else { throw ServiceFailure.invalidResponse }
        do {
            return try await AccountClient(transport: transport).call(
                payload,
                account: accountID,
                revision: accountRevision
            )
        } catch let failure as ServiceFailure {
            if failure.code == "providerFailure", let details = failure.details {
                throw try ServiceCodec.decode(ChatError.self, from: details)
            }
            throw failure
        }
    }

    private func consume(generation: UUID) async {
        var failures = 0
        while !Task.isCancelled, generation == connectionGeneration {
            do {
                let request = try ServiceRequest(header: ServiceRequestHeader(
                    requestID: ServiceRequestID(UUID().uuidString), accountID: accountID,
                    accountRevision: accountRevision
                ), payload: ReadEvents(cursor: cursor, limit: 256))
                let stream = try await transport.events(request)
                for try await page in stream {
                    try Task.checkCancellation()
                    try await receive(page, generation: generation)
                    if page.hasMore {
                        try await catchUp(generation: generation)
                    }
                    failures = 0
                }
                try Task.checkCancellation()
                throw ServiceFailure.invalidResponse
            } catch {
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                if error as? ServiceFailure == .authenticationRequired {
                    failProjectionWaiters(ServiceFailure.authenticationRequired)
                    emitTransient(.backendError(.unknown("This account needs to sign in again.")))
                    return
                }
                if error as? ServiceFailure == .staleAccount {
                    failProjectionWaiters(ServiceFailure.staleAccount)
                    emitTransient(
                        .backendError(.unknown("The account sign-in has changed. Reconnect this client."))
                    )
                    return
                }
                failures = min(6, failures + 1)
                emitTransportUnavailable()
                do {
                    try await Task.sleep(for: .milliseconds(250 * (1 << failures)))
                } catch {
                    return
                }
            }
        }
    }

    private func catchUp(generation: UUID) async throws {
        while !Task.isCancelled {
            let page = try await call(ReadEvents(cursor: cursor, limit: 256))
            try await receive(page, generation: generation)
            if !page.hasMore {
                return
            }
        }
        throw CancellationError()
    }

    private func receive(_ page: ServiceEventPage, generation: UUID) async throws {
        guard page.checkpoint.accountID == accountID else { throw ServiceFailure.invalidResponse }
        if let snapshot = page.snapshot {
            resynchronization = UUID()
            try await deliver(ChatDelivery(
                checkpoint: page.checkpoint.replicaCheckpoint,
                events: snapshot,
                isSnapshot: true,
                isLive: false, clientTransportAvailable: true
            ), generation: generation)
        } else {
            for event in page.events {
                if let cursor {
                    if event.cursor.streamID == cursor.streamID,
                       event.cursor.sequence <= cursor.sequence {
                        continue
                    }
                    guard cursor.sequence < UInt64.max, event.cursor.streamID == cursor.streamID,
                          event.cursor.sequence == cursor.sequence + 1 else {
                        throw ServiceFailure.invalidResponse
                    }
                }
                try await deliver(ChatDelivery(
                    checkpoint: event.cursor.replicaCheckpoint,
                    events: [event.event],
                    isSnapshot: false,
                    isLive: event.isLiveArrival, clientTransportAvailable: true
                ), generation: generation)
            }
            if page.events.isEmpty {
                try await deliver(ChatDelivery(
                    checkpoint: page.checkpoint.replicaCheckpoint, events: [], isSnapshot: false,
                    isLive: false, clientTransportAvailable: true
                ), generation: generation)
            }
        }
    }

    private func deliver(_ delivery: ChatDelivery, generation: UUID) async throws {
        guard generation == connectionGeneration else { throw CancellationError() }
        guard let checkpoint = delivery.checkpoint else { throw ServiceFailure.invalidResponse }
        if checkpointed {
            let applied = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled,
                          let deliverySink else { continuation.resume(returning: false); return }
                    acknowledgement = PendingAcknowledgement(
                        checkpoint: checkpoint,
                        generation: generation,
                        continuation: continuation
                    )
                    if case .enqueued = deliverySink.yield(delivery) {
                        return
                    }
                    acknowledgement = nil
                    continuation.resume(returning: false)
                }
            } onCancel: {
                Task { await self.cancelAcknowledgement(generation: generation) }
            }
            guard applied else { throw ServiceFailure.invalidResponse }
        } else {
            for event in delivery.events {
                let event = if !delivery.isLive, case let .messageReceived(message) = event {
                    ChatEvent.messageUpdated(message)
                } else {
                    event
                }
                if case .dropped = eventSink.yield(event) {
                    cursor = nil
                    throw ServiceFailure.overloaded
                }
            }
        }
        cursor = ServiceCursor(checkpoint)
        advanceProjectionWaiters()
    }

    private func cancelAcknowledgement(generation: UUID? = nil) {
        guard let pending = acknowledgement,
              generation == nil || generation == pending.generation else { return }
        acknowledgement = nil
        pending.continuation.resume(returning: false)
    }

    private func emitTransient(_ event: ChatEvent) {
        if checkpointed {
            deliverySink?.yield(ChatDelivery(
                checkpoint: nil,
                events: [event],
                isSnapshot: false,
                isLive: false
            ))
        } else {
            eventSink.yield(event)
        }
    }

    private func emitTransportUnavailable() {
        if checkpointed {
            deliverySink?.yield(ChatDelivery(
                checkpoint: nil, events: [], isSnapshot: false, isLive: false,
                clientTransportAvailable: false
            ))
        }
    }
}
