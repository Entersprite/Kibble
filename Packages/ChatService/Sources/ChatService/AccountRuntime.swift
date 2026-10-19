import ChatAPI
import ChatKit
import ChatRules
import Foundation

enum RuntimeFault: Sendable { case authentication, storage }

struct RuntimeIncident: Sendable {
    let generation: String
    let instanceID: UUID
    let fault: RuntimeFault
}

actor AccountRuntime {
    nonisolated let instanceID: UUID
    private let onStatus: @Sendable (RuntimeStatus) async -> Void
    private let onFault: @Sendable (RuntimeFault) async -> Void
    private var quarantined = false
    var quarantinedForSubscription: Bool {
        quarantined
    }

    private var stopDrained = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    let record: AccountRecord
    let storage: any ServiceAccountStorage
    private let factory: any AccountProviderFactory
    private var epoch = UUID()
    var subscribers: [UUID: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    var stopped = false
    private var backend: (any ChatBackend)?
    private var startup: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var requests: [UUID: Task<JSONValue, any Error>] = [:]
    private(set) var connection: ConnectionState = .idle
    private(set) var capabilities = Capabilities()

    init(
        record: AccountRecord,
        storage: any ServiceAccountStorage,
        factory: any AccountProviderFactory,
        instanceID: UUID, onStatus: @escaping @Sendable (RuntimeStatus) async -> Void,
        onFault: @escaping @Sendable (RuntimeFault) async -> Void
    ) {
        self.instanceID = instanceID
        self.onStatus = onStatus
        self.onFault = onFault
        self.record = record
        self.storage = storage
        self.factory = factory
    }

    func start() {
        guard startup == nil, !stopped else { return }
        let epoch = epoch
        startup = Task { [weak self, factory, record] in
            do {
                let provider = try await factory.makeProvider(for: record)
                guard let self, await install(provider.backend, epoch: epoch) else {
                    await provider.backend.disconnect()
                    return
                }
                try await provider.backend.connect()
                if await !isCurrent(epoch) {
                    await provider.backend.disconnect()
                }
            } catch {
                await self?.failed(error, epoch: epoch)
            }
        }
    }

    private func install(_ backend: any ChatBackend, epoch: UUID) async -> Bool {
        guard self.epoch == epoch, !stopped, !Task.isCancelled else { return false }
        self.backend = backend
        capabilities = backend.capabilities
        let events = backend.events
        consumer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.ingest(event, epoch: epoch)
            }
        }
        await publishStatus()
        return isCurrent(epoch)
    }

    private func publishStatus() async {
        await onStatus(RuntimeStatus(connection: connection, capabilities: capabilities))
    }

    private func isCurrent(_ epoch: UUID) -> Bool {
        self.epoch == epoch && !stopped && !quarantined && !Task.isCancelled
    }

    private func ingest(_ event: ChatEvent, epoch: UUID) async {
        guard self.epoch == epoch, !stopped, !quarantined else { return }
        switch event {
        case .backendError(.notAuthenticated), .backendError(.sessionExpired):
            await quarantine(.authentication)
            return
        case let .selfIdentified(member) where member.id != record.selfID:
            await quarantine(.authentication)
            return
        default: break
        }
        do {
            try appendAndPublish(event, live: true)
            if case .connectionStateChanged = event {
                await publishStatus()
            }
        } catch {
            await quarantine(.storage)
        }
    }

    private func appendAndPublish(_ event: ChatEvent, live: Bool) throws {
        let cursor = try storage.append(event, live: live)
        try publish(ServiceEventPage(
            checkpoint: cursor,
            snapshot: nil,
            events: [ServiceEvent(cursor: cursor, event: event, isLiveArrival: live)],
            hasMore: false
        ))
        if case let .connectionStateChanged(state) = event {
            connection = state
        }
    }

    private func failed(_ error: any Error, epoch: UUID) async {
        guard self.epoch == epoch, !stopped, !quarantined else { return }
        if error as? ChatError == .notAuthenticated || error as? ChatError == .sessionExpired {
            await quarantine(.authentication)
            return
        }
        let failure = serviceFailure(error)
        let safe = failure.details.flatMap { try? ServiceCodec.decode(ChatError.self, from: $0) }
            ?? .unknown("The account could not connect.")
        do {
            try appendAndPublish(.backendError(safe), live: false)
            try appendAndPublish(.connectionStateChanged(.disconnected(reason: nil, issue: nil)), live: false)
            await publishStatus()
        } catch {
            await quarantine(.storage)
        }
    }

    private func quarantine(_ fault: RuntimeFault) async {
        guard !quarantined, !stopped else { return }
        quarantined = true
        epoch = UUID()
        connection = .disconnected(reason: nil, issue: nil)
        consumer?.cancel()
        for request in requests.values {
            request.cancel()
        }
        for subscriber in subscribers
            .values {
            subscriber.finish(throwing: ServiceFailure.accountCleanupPending)
        }
        subscribers.removeAll()
        // The callback records/schedules recovery and returns without awaiting
        // teardown, which must be able to drain this consumer/startup task.
        await onFault(fault)
    }

    func stop() async {
        if stopped {
            if !stopDrained {
                await withCheckedContinuation { stopWaiters.append($0) }
            }
            return
        }
        stopped = true
        for subscriber in subscribers.values {
            subscriber.finish(throwing: ServiceFailure.accountDisabled)
        }
        subscribers.removeAll()
        epoch = UUID()
        startup?.cancel()
        consumer?.cancel()
        let pending = Array(requests.values)
        for request in pending {
            request.cancel()
        }
        await backend?.disconnect()
        for request in pending {
            _ = await request.result
        }
        await startup?.value
        await consumer?.value
        backend = nil
        startup = nil
        consumer = nil
        connection = .disconnected(reason: nil, issue: nil)
        _ = try? storage.append(.connectionStateChanged(.disconnected(reason: nil, issue: nil)), live: false)
        stopDrained = true
        let waiting = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }

    func handle(_ request: ServiceRequest) async throws -> JSONValue {
        guard !stopped else { throw ServiceFailure.accountDisabled }
        guard !quarantined else { throw ServiceFailure.accountCleanupPending }
        guard requests.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let epoch = epoch
        let work = Task { try await dispatch(request, epoch: epoch) }
        requests[id] = work
        defer { requests[id] = nil }
        return try await withTaskCancellationHandler {
            do {
                return try await work.value
            } catch {
                if error as? ChatError == .sessionExpired {
                    await quarantine(.authentication)
                    throw ServiceFailure.accountCleanupPending
                }
                throw error
            }
        } onCancel: {
            work.cancel()
        }
    }

    private func dispatch(_ request: ServiceRequest, epoch: UUID) async throws -> JSONValue {
        try Task.checkCancellation()
        switch request.operation {
        case ReadEvents.operation:
            let payload = try request.decodePayload(ReadEvents.self)
            return try ServiceCodec.value(storage.readEvents(after: payload.cursor, limit: payload.limit))
        case GetOperation.operation:
            let payload = try request.decodePayload(GetOperation.self)
            guard let result = try storage.operation(payload.operationID)
            else { throw ServiceFailure.operationUnknown }
            return try ServiceCodec.value(result)
        default: break
        }
        guard let backend else { throw ServiceFailure.overloaded }
        guard !stopped, self.epoch == epoch else { throw ServiceFailure.accountDisabled }
        return try await dispatchProvider(request, backend: backend, epoch: epoch)
    }

    func checkEpoch(_ epoch: UUID) throws {
        guard !stopped, self.epoch == epoch else { throw ServiceFailure.accountDisabled }
        try Task.checkCancellation()
    }

    func performOperation(
        _ id: ServiceOperationID, request: ServiceRequest, epoch: UUID,
        perform: @Sendable () async throws -> some Codable & Sendable
    ) async throws -> JSONValue {
        let operation = try storage.reserve(id, request: request)
        switch operation.state {
        case "succeeded":
            guard let result = operation.result else { throw ServiceFailure.invalidResponse }
            return result
        case "failed": throw operation.failure ?? ServiceFailure.internalFailure
        case "accepted": break
        default: throw ServiceFailure.operationUnknown
        }
        try checkEpoch(epoch)
        try storage.finish(ServiceOperation(id: id, state: "dispatching"))
        do {
            let result = try await ServiceCodec.value(perform())
            try storage.finish(ServiceOperation(id: id, state: "succeeded", result: result))
            return result
        } catch {
            if error as? ChatError == .sessionExpired {
                await quarantine(.authentication)
            }
            // Once dispatch starts, an error alone does not establish non-execution.
            try storage.finish(ServiceOperation(id: id, state: "unknown", failure: serviceFailure(error)))
            throw ServiceFailure.operationUnknown
        }
    }
}
