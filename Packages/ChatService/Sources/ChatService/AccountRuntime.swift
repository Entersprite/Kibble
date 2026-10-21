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
    let onProfile: @Sendable (AccountProfile) async -> Void
    private var quarantined = false

    private var stopDrained = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    let record: AccountRecord
    let storage: any ServiceAccountStorage
    let policies: any AccountPolicyStore
    private let factory: any AccountProviderFactory
    private let providerStarts: AccountWorkAdmission
    let providerStops: AccountWorkAdmission
    let providerWork: AccountWorkAdmission
    let callCleanupAdmission: AccountWorkAdmission
    private var epoch = UUID()

    var subscribers: [UUID: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    var subscriberAttachments: [UUID: ClientAttachmentID] = [:]
    var clientInterests: [ClientInterestKey: ClientInterestSlot] = [:]
    var interestSweep: Task<Void, Never>?
    var interestPublisher: Task<Void, Never>?
    var interestFault: Task<Void, Never>?
    var interestRevision: UInt64 = 0
    var publishedInterestRevision: UInt64 = 0
    var interestDirty = false
    var forceInterestPublish = false
    var publishedInterests = ClientInterestAggregate()
    var interestWaiters: [UUID: ClientInterestWaiter] = [:]
    var typingRefreshRequested: Set<ClientTypingTarget> = []
    var typingStartInFlight = false
    var stopped = false
    var checkpointedBackend: (any ProviderCheckpointBackend)?
    var backend: (any ChatBackend)?
    var now: @Sendable () -> Date = { Date() }
    var mediaFactsVersion = UUID()
    var resourceSync: [ResourceSyncAddress: ResourceSyncStatus] = [:]
    var reads = AccountReadState()
    var worldVersion = UUID()
    var historyWorldVersion = UUID()
    var historyVersions: [Conversation.ID: UUID] = [:]
    var worldRefresh: Task<Void, Never>?
    var worldRefreshRequested = false
    var historyRefresh: Task<Void, Never>?
    var pendingHistory: Set<Conversation.ID> = []
    var backfill: Task<Void, Never>?
    var backfillRequested = false
    var backfillReplayRequested = false
    var backfillHeads: [Conversation.ID: MentionBackfillHead] = [:]
    var profileRefresh: Task<Void, Never>?
    var pendingSelf: Member?
    private var startup: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    var requests: [UUID: Task<JSONValue, any Error>] = [:]
    var binaryRequests: [UUID: Task<ServiceBinaryFrame, any Error>] = [:]
    var transferStorage: (any ServiceTransferStorage)?
    let transferLimits: ServiceTransferLimits
    let transferNow: @Sendable () -> Date
    let notificationHost: (any ServiceNotificationHost)?
    let notificationService: ServiceInstanceID
    var notificationJob: Task<Void, Never>?
    var notificationDirty = false
    let callReservations: CallDeviceReservations
    var calls: [ServiceDeviceID: ServiceCallRuntime] = [:]
    var callStops: [Task<Void, Never>] = []
    var callWorldVersion = UUID()
    var callFactsVersions: [Conversation.ID: UUID] = [:]
    var uploads: [ServiceTransferID: UploadSlot] = [:]
    var downloads: [ServiceTransferID: DownloadSlot] = [:]
    var uploadExpiry: Task<Void, Never>?
    private(set) var connection: ConnectionState = .idle
    private(set) var capabilities = Capabilities()

    init(
        record: AccountRecord,
        storage: any ServiceAccountStorage,
        factory: any AccountProviderFactory,
        policies: any AccountPolicyStore,
        instanceID: UUID,
        notificationHost: (any ServiceNotificationHost)? = nil,
        notificationService: ServiceInstanceID = ServiceInstanceID("embedded"),
        callReservations: CallDeviceReservations = CallDeviceReservations(),
        providerStarts: AccountWorkAdmission = AccountWorkAdmission(limit: 4),
        providerStops: AccountWorkAdmission = AccountWorkAdmission(limit: 8),
        providerWork: AccountWorkAdmission = AccountWorkAdmission(limit: 16, perOwnerLimit: 4),
        callCleanupAdmission: AccountWorkAdmission = AccountWorkAdmission(limit: 8),
        transferStorage: (any ServiceTransferStorage)? = nil,
        transferLimits: ServiceTransferLimits = ServiceTransferLimits(),
        transferNow: @escaping @Sendable () -> Date = { Date() },
        onStatus: @escaping @Sendable (RuntimeStatus) async -> Void,
        onProfile: @escaping @Sendable (AccountProfile) async -> Void = { _ in },
        onFault: @escaping @Sendable (RuntimeFault) async -> Void
    ) {
        self.instanceID = instanceID
        self.notificationHost = notificationHost
        self.notificationService = notificationService
        self.callReservations = callReservations
        self.callCleanupAdmission = callCleanupAdmission
        self.providerWork = providerWork
        self.providerStarts = providerStarts; self.providerStops = providerStops
        self.transferStorage = transferStorage
        self.transferLimits = transferLimits
        self.transferNow = transferNow
        self.onStatus = onStatus
        self.onProfile = onProfile
        self.onFault = onFault
        self.record = record
        self.storage = storage
        self.factory = factory
        self.policies = policies
    }

    func start() {
        guard startup == nil, !stopped else { return }
        let epoch = epoch
        startup = Task { [weak self, factory, record, providerStarts, instanceID] in
            do { try await providerStarts.acquire(instanceID) } catch { return }
            do {
                try Task.checkCancellation()
                let provider = try await factory.makeProvider(for: record)
                guard let self, await install(provider, epoch: epoch) else {
                    await provider.discard()
                    await providerStarts.release(instanceID)
                    return
                }
                if let source = await checkpointedBackend,
                   let storage = await storage as? any ServiceProviderCheckpointStorage {
                    try Task.checkCancellation()
                    try await source.connect(resumingProviderCheckpoint: storage.providerCheckpoint())
                } else {
                    try await provider.backend.connect()
                }
                if await !isCurrent(epoch) {
                    await provider.discard()
                } else {
                    if await checkpointedBackend == nil {
                        await requestWorldRefresh()
                    }
                }
            } catch {
                await self?.failed(error, epoch: epoch)
            }
            await providerStarts.release(instanceID)
        }
    }

    private func install(_ provider: AccountProvider, epoch: UUID) async -> Bool {
        guard self.epoch == epoch, !stopped, !Task.isCancelled else { return false }
        let backend = provider.backend
        now = provider.now
        self.backend = backend
        if interestDirty {
            clientInterestsChanged()
        }
        capabilities = installedCapabilities(from: backend)
        if let source = backend as? any ProviderCheckpointBackend, await source.usesProviderCheckpoints() {
            guard self.epoch == epoch, !stopped, !Task.isCancelled else { return false }
            guard storage is any ServiceProviderCheckpointStorage else {
                await quarantine(.storage)
                return false
            }
            checkpointedBackend = source
            consumer = Task { [weak self] in await self?.consumeProviderBatches(from: source, epoch: epoch) }
        } else {
            guard self.epoch == epoch, !stopped, !Task.isCancelled else { return false }
            let events = backend.events
            consumer = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.ingest(event, epoch: epoch)
                }
            }
        }
        await installCalls(provider.calls)
        await publishStatus()
        notificationsChanged()
        return isCurrent(epoch)
    }

    @discardableResult
    func appendAndPublish(_ event: ChatEvent, live: Bool) throws -> ServiceCursor {
        invalidateCallFacts(for: event)
        let cursor = try storage.append(event, live: live)
        if !SyncReducer.reduce(event).effects.isEmpty {
            notificationsChanged()
        }
        invalidateMediaQueries(for: event)
        try publish(ServiceEventPage(
            checkpoint: cursor,
            snapshot: nil,
            events: [ServiceEvent(cursor: cursor, event: event, isLiveArrival: live)],
            hasMore: false
        ))
        if case let .resourceSyncChanged(status) = event {
            resourceSyncCommitted(status)
        }
        if case let .connectionStateChanged(state) = event {
            connection = state
        }
        return cursor
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

    func quarantine(_ fault: RuntimeFault) async {
        guard !quarantined, !stopped else { return }
        quarantined = true
        epoch = UUID()
        connection = .disconnected(reason: nil, issue: nil)
        consumer?.cancel()
        notificationJob?.cancel()
        _ = stopCalls()
        for request in requests.values {
            request.cancel()
        }
        _ = cancelClientInterestJobs()
        for task in reads.workers {
            task.cancel()
        }
        _ = cancelUploadJobs()
        for request in binaryRequests.values {
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
        let effects = [worldRefresh, historyRefresh, backfill, notificationJob, profileRefresh]
            .compactMap(\.self) + cancelClientInterestJobs() + reads.workers
        for task in effects {
            task.cancel()
        }
        let callCleanup = stopCalls()
        let pending = Array(requests.values)
        let binaries = Array(binaryRequests.values)
        let expiry = cancelUploadJobs()
        for request in binaries {
            request.cancel()
        }
        for request in pending {
            request.cancel()
        }
        await drainRequests(pending, binaries: binaries, expiry: expiry, effects: effects + callCleanup)
        await withdrawHostNotifications()
        notificationJob = nil
        calls = [:]; callStops = []
        worldRefresh = nil; historyRefresh = nil; backfill = nil; profileRefresh = nil; pendingSelf = nil
        pendingHistory.removeAll(); backfillHeads.removeAll(); historyVersions.removeAll()
        clientInterests.removeAll(); subscriberAttachments.removeAll()
        interestSweep = nil; interestPublisher = nil; interestFault = nil; typingRefreshRequested.removeAll()
        reads = AccountReadState()
        checkpointedBackend = nil
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
}

extension AccountRuntime {
    func ingest(_ event: ChatEvent, epoch: UUID) async {
        guard self.epoch == epoch, !stopped, !quarantined else { return }
        switch event {
        case .backendError(.notAuthenticated), .backendError(.sessionExpired):
            await quarantine(.authentication)
            return
        case let .resourceSyncChanged(status)
            where status.error == .sessionExpired:
            await quarantine(.authentication)
            return
        case let .selfIdentified(member) where member.id != record.selfID:
            await quarantine(.authentication)
            return
        default: break
        }
        do {
            invalidateQueries(for: event)
            try appendAndPublish(event, live: true)
            await scheduleEffects(for: event)
            if case .connectionStateChanged = event {
                await publishStatus()
            }
        } catch {
            await quarantine(.storage)
        }
    }

    private func drainRequests(
        _ pending: [Task<JSONValue, any Error>], binaries: [Task<ServiceBinaryFrame, any Error>],
        expiry: Task<Void, Never>?, effects: [Task<Void, Never>]
    ) async {
        if let backend {
            await providerStops.cleanup { await backend.disconnect() }
        }
        for request in pending {
            _ = await request.result
        }
        for request in binaries {
            _ = await request.result
        }
        await expiry?.value
        await closeUploadStorage()
        await startup?.value
        await consumer?.value
        for task in effects {
            await task.value
        }
    }

    var quarantinedForSubscription: Bool {
        quarantined
    }

    var currentEpoch: UUID {
        epoch
    }

    func publishProviderStatus() async {
        await publishStatus()
    }

    func setProviderConnection(_ value: ConnectionState) {
        connection = value
    }

    private func publishStatus() async {
        await onStatus(RuntimeStatus(connection: connection, capabilities: capabilities))
    }

    private func isCurrent(_ epoch: UUID) -> Bool {
        self.epoch == epoch && !stopped && !quarantined && !Task.isCancelled
    }
}
