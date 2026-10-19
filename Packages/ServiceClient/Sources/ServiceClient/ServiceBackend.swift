import ChatAPI
import ChatKit
import Foundation

/// One client/account adapter. Its lifecycle changes subscriptions, never providers.
public actor ServiceBackend: CheckpointedChatBackend {
    public nonisolated let capabilities: Capabilities
    public nonisolated let events: AsyncStream<ChatEvent>
    let transport: any ServiceEventTransport
    let accountID: ConnectedAccountID
    private let eventSink: AsyncStream<ChatEvent>.Continuation
    private var deliverySink: AsyncStream<ChatDelivery>.Continuation?
    private var checkpointed = false
    private var cursor: ServiceCursor?
    private var consumer: Task<Void, Never>?
    private var acknowledgement: (ReplicaCheckpoint, CheckedContinuation<Bool, Never>)?

    public init(account: AccountSummary, transport: any ServiceEventTransport) {
        accountID = account.id
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
        guard let pending = acknowledgement, pending.0 == checkpoint else { return }
        acknowledgement = nil
        pending.1.resume(returning: applied)
    }

    public func connect() async throws {
        guard consumer == nil else { return }
        _ = try await transport.negotiate(.current)
        guard consumer == nil else { return }
        consumer = Task { [weak self] in await self?.consume() }
    }

    public func disconnect() async {
        let task = consumer
        consumer = nil
        task?.cancel()
        cancelAcknowledgement()
        await task?.value
        emitTransient(.connectionStateChanged(.disconnected(reason: nil, issue: nil)))
    }

    public func call<Payload: ServiceRequestPayload>(_ payload: Payload) async throws -> Payload.Response {
        do {
            return try await AccountClient(transport: transport).call(payload, account: accountID)
        } catch let failure as ServiceFailure {
            if failure.code == "providerFailure", let details = failure.details {
                throw try ServiceCodec.decode(ChatError.self, from: details)
            }
            throw failure
        }
    }

    private func consume() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let request = try ServiceRequest(header: ServiceRequestHeader(
                    requestID: ServiceRequestID(UUID().uuidString), accountID: accountID
                ), payload: ReadEvents(cursor: cursor, limit: 256))
                let stream = try await transport.events(request)
                for try await page in stream {
                    try Task.checkCancellation()
                    try await receive(page)
                    failures = 0
                }
                try Task.checkCancellation()
                throw ServiceFailure.invalidResponse
            } catch {
                guard !Task.isCancelled else { return }
                failures = min(6, failures + 1)
                emitTransient(.backendError(.transport("The account connection was interrupted. Retrying…")))
                do {
                    try await Task.sleep(for: .milliseconds(250 * (1 << failures)))
                } catch {
                    return
                }
            }
        }
    }

    private func receive(_ page: ServiceEventPage) async throws {
        guard page.checkpoint.accountID == accountID else { throw ServiceFailure.invalidResponse }
        if let snapshot = page.snapshot {
            try await deliver(ChatDelivery(
                checkpoint: page.checkpoint.replicaCheckpoint,
                events: snapshot,
                isSnapshot: true,
                isLive: false
            ))
        } else {
            for event in page.events {
                if let cursor {
                    guard cursor.sequence < UInt64.max, event.cursor.streamID == cursor.streamID,
                          event.cursor.sequence == cursor.sequence + 1 else {
                        throw ServiceFailure.invalidResponse
                    }
                }
                try await deliver(ChatDelivery(
                    checkpoint: event.cursor.replicaCheckpoint,
                    events: [event.event],
                    isSnapshot: false,
                    isLive: event.isLiveArrival
                ))
            }
        }
    }

    private func deliver(_ delivery: ChatDelivery) async throws {
        guard let checkpoint = delivery.checkpoint else { throw ServiceFailure.invalidResponse }
        if checkpointed {
            let applied = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled,
                          let deliverySink else { continuation.resume(returning: false); return }
                    acknowledgement = (checkpoint, continuation)
                    if case .enqueued = deliverySink.yield(delivery) {
                        return
                    }
                    acknowledgement = nil
                    continuation.resume(returning: false)
                }
            } onCancel: {
                Task { await self.cancelAcknowledgement() }
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
    }

    private func cancelAcknowledgement() {
        let pending = acknowledgement
        acknowledgement = nil
        pending?.1.resume(returning: false)
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
}
