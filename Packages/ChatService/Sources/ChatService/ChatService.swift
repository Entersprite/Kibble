import ChatAPI
import ChatKit
import Foundation

/// Account runtimes belong to this host, independently of client subscriptions.
public actor ChatService: ServiceEventEndpoint, ServiceAccountStateEndpoint {
    let registry: any AccountRegistry
    let storage: any ServiceStorageFactory
    let providers: any AccountProviderFactory
    let transferFiles: (any ServiceTransferStorageFactory)?
    let transferLimits: ServiceTransferLimits
    let transferNow: @Sendable () -> Date
    let notificationHost: (any ServiceNotificationHost)?
    let callReservations = CallDeviceReservations()
    let providerStarts: AccountWorkAdmission
    let providerStops: AccountWorkAdmission
    var records: [ConnectedAccountID: AccountRecord] = [:]
    var runtimes: [ConnectedAccountID: AccountRuntime] = [:]
    var changing: Set<ConnectedAccountID> = []
    var deferredFaults: [ConnectedAccountID: RuntimeIncident] = [:]
    var maintenance: [ConnectedAccountID: Task<Void, Never>] = [:]
    let linkCustody: (any AccountLinkCustody)?
    var links: [AccountLinkID: AccountLinkRecord] = [:]
    var linkTasks: [AccountLinkID: Task<AccountLinkSummary, any Error>] = [:]
    let policies: any AccountPolicyStore
    let instanceID: ServiceInstanceID
    var policyRevisions: [ConnectedAccountID: String] = [:]
    private let ownership: (any ServiceOwnership)?
    private var lease: (any ServiceOwnershipLease)?
    private var drained: [CheckedContinuation<Void, Never>] = []
    var accountSubscribers: [UUID: AccountStateSubscriber] = [:]
    var runtimeStatuses: [ConnectedAccountID: RuntimeStatusEntry] = [:]
    let maximumAccountSubscriptions: Int
    private var restored = false
    var restoredForSubscriptions: Bool {
        restored
    }

    var shuttingDown = false
    private var shutdownFinished = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        registry: any AccountRegistry,
        storage: any ServiceStorageFactory,
        providers: any AccountProviderFactory,
        transferFiles: (any ServiceTransferStorageFactory)? = nil,
        transferLimits: ServiceTransferLimits = ServiceTransferLimits(),
        transferNow: @escaping @Sendable () -> Date = { Date() },
        linkCustody: (any AccountLinkCustody)? = nil,
        ownership: (any ServiceOwnership)? = nil,
        policies: (any AccountPolicyStore)? = nil,
        notificationHost: (any ServiceNotificationHost)? = nil,
        maximumAccountSubscriptions: Int = 128,
        maximumConcurrentProviderStarts: Int = 4, maximumConcurrentProviderStops: Int = 8,
        instanceID: ServiceInstanceID = ServiceInstanceID(UUID().uuidString)
    ) {
        providerStarts = AccountWorkAdmission(limit: maximumConcurrentProviderStarts)
        providerStops = AccountWorkAdmission(limit: maximumConcurrentProviderStops)
        self.maximumAccountSubscriptions = max(0, maximumAccountSubscriptions)
        self.instanceID = instanceID
        self.registry = registry
        self.storage = storage
        self.providers = providers
        self.transferFiles = transferFiles
        self.transferLimits = transferLimits
        self.transferNow = transferNow
        self.notificationHost = notificationHost
        self.linkCustody = linkCustody
        self.ownership = ownership
        self.policies = policies ?? (registry as? any AccountPolicyStore) ?? UnavailableAccountPolicyStore()
    }

    public func restore() async throws {
        guard !shuttingDown else { throw ServiceFailure.overloaded }
        guard !restored else { return }
        let acquired = try ownership?.acquire()
        let accounts: [AccountRecord]
        do {
            accounts = try registry.accounts()
            if let linkRegistry = registry as? any AccountLinkRegistry {
                links = try Dictionary(uniqueKeysWithValues: linkRegistry.links().map { ($0.id, $0) })
            }
        } catch {
            acquired?.release()
            throw error
        }
        lease = acquired
        records = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        restored = true
        for record in accounts
            where record.isEnabled && !record.isRemoving && record.authenticationState == nil {
            guard !shuttingDown else { return }
            // A damaged account cache must not prevent healthy accounts from
            // starting. Its next explicit enable request can retry the open.
            if let runtime = try? makeRuntime(record) {
                runtimes[record.id] = runtime
                await runtime.start()
            }
        }
        guard !shuttingDown else { return }
        for record in accounts where record.isRemoving {
            maintenance[record.id] = Task { await resumeRemoval(record) }
        }
        restoreAuthenticationRecovery()
        restoreLinks()
    }

    private func resumeRemoval(_ record: AccountRecord) async {
        try? await remove(record)
        maintenance[record.id] = nil
    }

    public func handle(_ bytes: Data, context: ServiceSessionContext) async throws -> Data {
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        let request = try ServiceCodec.decode(ServiceRequest.self, from: bytes)
        let result: ServiceResult
        do {
            _ = try ServiceAPIVersion.current.negotiated(with: request.header.version)
            guard restored, !shuttingDown else { throw ServiceFailure.overloaded }
            if let deadline = request.header.deadline,
               deadline <= Date() {
                throw ServiceFailure.deadlineExceeded
            }
            result = try await .success(route(request, context: context))
        } catch {
            result = .failure(serviceFailure(error))
        }
        return try ServiceCodec.encode(ServiceResponse(replyingTo: request, result: result))
    }

    public func events(
        _ bytes: Data,
        context: ServiceSessionContext
    ) async throws -> AsyncThrowingStream<Data, any Error> {
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        let request = try ServiceCodec.decode(ServiceRequest.self, from: bytes)
        _ = try ServiceAPIVersion.current.negotiated(with: request.header.version)
        if let deadline = request.header.deadline,
           deadline <= Date() {
            throw ServiceFailure.deadlineExceeded
        }
        let payload = try request.decodePayload(ReadEvents.self)
        guard restored, !shuttingDown,
              let id = request.header.accountID, context.allowsAccount(id),
              let record = records[id], record.principalID == context.principalID,
              !record.isRemoving else { throw ServiceFailure.notAuthorized }
        guard request.header.accountRevision == record.currentRevision
        else { throw ServiceFailure.staleAccount }
        guard record.isEnabled, !changing.contains(id) else {
            throw ServiceFailure.accountDisabled
        }
        guard let runtime = runtimes[id] else { throw ServiceFailure.overloaded }
        return try await runtime.subscribe(
            after: payload.cursor, attachment: payload.clientAttachmentID, context: context
        )
    }

    private func route(_ request: ServiceRequest, context: ServiceSessionContext) async throws -> JSONValue {
        if request.operation == GetServiceInfo.operation {
            return try serviceInfo(request)
        }
        if request.operation == ListAccounts.operation {
            _ = try request.decodePayload(ListAccounts.self)
            return try await listAccounts(context)
        }
        if request.operation == ListAccountLinks.operation {
            _ = try request.decodePayload(ListAccountLinks.self)
            guard context.canLinkAccounts else { throw ServiceFailure.notAuthorized }
            return try ServiceCodec.value(pendingLinks(context))
        }
        if Self.linkOperations.contains(request.operation) {
            return try await routeLink(request, context: context)
        }
        guard let id = request.header.accountID else { throw ServiceFailure.accountRequired }
        guard context.allowsAccount(id), let record = records[id],
              record.principalID == context.principalID else { throw ServiceFailure.notAuthorized }
        guard request.header.accountRevision == record.currentRevision
        else { throw ServiceFailure.staleAccount }
        if record.isRemoving, request.operation != RemoveAccount.operation {
            throw ServiceFailure.accountDisabled
        }
        return try await routeAccount(request, record: record, context: context)
    }

    private func routeAccount(
        _ request: ServiceRequest, record: AccountRecord, context: ServiceSessionContext
    ) async throws -> JSONValue {
        let id = record.id
        switch request.operation {
        case RetryAccountRecovery.operation:
            _ = try request.decodePayload(RetryAccountRecovery.self)
            return try await ServiceCodec.value(retryAuthenticationRecovery(record))
        case SetAccountEnabled.operation:
            let payload = try request.decodePayload(SetAccountEnabled.self)
            return try await ServiceCodec.value(setEnabled(payload.enabled, record: record))
        case RemoveAccount.operation:
            _ = try request.decodePayload(RemoveAccount.self)
            try await remove(record)
            return try ServiceCodec.value(ServiceUnit())
        case GetAccountPolicy.operation, SetAccountPolicy.operation:
            guard !changing.contains(id) else { throw ServiceFailure.overloaded }
            return try await accountPolicy(request, record: record)
        case GetOperation.operation:
            try checkAuthentication(record)
            return try await accountOperationStatus(request, record: record)
        default:
            try checkAuthentication(record)
            guard record.isEnabled, !changing.contains(id) else { throw ServiceFailure.accountDisabled }
            guard let runtime = runtimes[id] else { throw ServiceFailure.overloaded }
            return try await runtime.handle(request, context: context)
        }
    }

    private func setEnabled(_ enabled: Bool, record: AccountRecord) async throws -> AccountSummary {
        guard record.authenticationState != "erasing" else { throw ServiceFailure.accountCleanupPending }
        guard !changing.contains(record.id) else { throw ServiceFailure.overloaded }
        changing.insert(record.id)
        defer { finishChange(record.id) }
        var record = record
        record.isEnabled = enabled
        try registry.save(record)
        records[record.id] = record
        accountStateChanged()
        if !enabled {
            if let runtime = runtimes[record.id] {
                await runtime.stop()
                runtimes[record.id] = nil
            }
        } else if runtimes[record.id] == nil, record.authenticationState == nil {
            let runtime = try makeRuntime(record)
            runtimes[record.id] = runtime
            await runtime.start()
        }
        return accountSummary(record)
    }

    private func remove(_ record: AccountRecord) async throws {
        guard !changing.contains(record.id) else { throw ServiceFailure.overloaded }
        changing.insert(record.id)
        defer { finishChange(record.id) }
        var removing = record
        removing.isEnabled = false
        removing.isRemoving = true
        try registry.save(removing)
        records[record.id] = removing
        accountStateChanged()
        if let runtime = runtimes[record.id] {
            await runtime.stop()
            runtimes[record.id] = nil
        }
        try await finishLinksForRemoval(removing)
        try await providers.forgetCredentials(for: removing)
        try transferFiles?.erase(record.id)
        try storage.erase(record.id)
        try registry.remove(record.id)
        records[record.id] = nil
        policyRevisions[record.id] = nil
        runtimeStatuses[record.id] = nil
        accountStateChanged()
    }

    public func shutdown() async {
        if shuttingDown {
            if !shutdownFinished {
                await withCheckedContinuation { shutdownWaiters.append($0) }
            }
            return
        }
        shuttingDown = true
        for subscriber in accountSubscribers.values {
            subscriber.continuation.finish()
        }
        accountSubscribers.removeAll()
        let linking = Array(linkTasks.values)
        for task in linking {
            task.cancel()
        }
        for task in linking {
            _ = await task.result
        }
        let cleanup = Array(maintenance.values)
        for task in cleanup {
            task.cancel()
        }
        for task in cleanup {
            await task.value
        }
        let all = Array(runtimes.values)
        await withTaskGroup(of: Void.self) { group in
            for runtime in all {
                group.addTask { await runtime.stop() }
            }
        }
        runtimes.removeAll()
        runtimeStatuses.removeAll()
        await awaitChanges()
        lease?.release()
        lease = nil
        shutdownFinished = true
        let waiters = shutdownWaiters
        shutdownWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension ChatService {
    func finishChange(_ id: ConnectedAccountID) {
        changing.remove(id)
        if runtimes[id] == nil {
            runtimeStatuses[id] = nil
        }
        accountStateChanged()
        if let incident = deferredFaults.removeValue(forKey: id) {
            runtimeFailed(
                id,
                generation: incident.generation,
                instanceID: incident.instanceID,
                fault: incident.fault
            )
        }
        guard changing.isEmpty else { return }
        let waiting = drained
        drained.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    private func awaitChanges() async {
        guard !changing.isEmpty else { return }
        await withCheckedContinuation { drained.append($0) }
    }

    public var activeRuntimeCount: Int {
        runtimes.count
    }
}
