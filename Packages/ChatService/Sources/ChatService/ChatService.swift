import ChatAPI
import ChatKit
import Foundation

/// Account runtimes belong to this host, independently of client subscriptions.
public actor ChatService: ServiceEventEndpoint {
    let registry: any AccountRegistry
    let storage: any ServiceStorageFactory
    let providers: any AccountProviderFactory
    var records: [ConnectedAccountID: AccountRecord] = [:]
    var runtimes: [ConnectedAccountID: AccountRuntime] = [:]
    var changing: Set<ConnectedAccountID> = []
    var deferredFaults: [ConnectedAccountID: RuntimeIncident] = [:]
    var maintenance: [ConnectedAccountID: Task<Void, Never>] = [:]
    let linkCustody: (any AccountLinkCustody)?
    var links: [AccountLinkID: AccountLinkRecord] = [:]
    var linkTasks: [AccountLinkID: Task<AccountLinkSummary, any Error>] = [:]
    let policies: any AccountPolicyStore
    private let ownership: (any ServiceOwnership)?
    private var lease: (any ServiceOwnershipLease)?
    private var drained: [CheckedContinuation<Void, Never>] = []
    private var restored = false
    var shuttingDown = false

    public init(
        registry: any AccountRegistry,
        storage: any ServiceStorageFactory,
        providers: any AccountProviderFactory,
        linkCustody: (any AccountLinkCustody)? = nil,
        ownership: (any ServiceOwnership)? = nil,
        policies: (any AccountPolicyStore)? = nil
    ) {
        self.registry = registry
        self.storage = storage
        self.providers = providers
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

    /// Host-only admission after credential validation; no client DTO grants this authority.
    public func registerVerified(_ record: AccountRecord) async throws {
        guard restored, !shuttingDown, !record.isRemoving,
              record.authenticationState == nil else { throw ServiceFailure.invalidRequest }
        guard records[record.id] == nil,
              !records.values
              .contains(where: { $0.principalID == record.principalID && $0.selfID == record.selfID }) else {
            throw ServiceFailure.operationConflict
        }
        try registry.save(record)
        records[record.id] = record
        if record.isEnabled {
            let runtime = try makeRuntime(record)
            runtimes[record.id] = runtime
            await runtime.start()
        }
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
        return try await runtime.subscribe(after: payload.cursor)
    }

    private func route(_ request: ServiceRequest, context: ServiceSessionContext) async throws -> JSONValue {
        if request.operation == ListAccounts.operation {
            _ = try request.decodePayload(ListAccounts.self)
            return try await listAccounts(context)
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
        return try await routeAccount(request, record: record)
    }

    private func routeAccount(_ request: ServiceRequest, record: AccountRecord) async throws -> JSONValue {
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
            return try accountPolicy(request, record: record)
        case GetOperation.operation:
            try checkAuthentication(record)
            return try await accountOperationStatus(request, record: record)
        default:
            try checkAuthentication(record)
            guard record.isEnabled, !changing.contains(id) else { throw ServiceFailure.accountDisabled }
            guard let runtime = runtimes[id] else { throw ServiceFailure.overloaded }
            return try await runtime.handle(request)
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
        return AccountSummary(
            id: record.id,
            selfID: record.selfID,
            label: record.label,
            connection: .idle,
            isEnabled: enabled, revision: record.currentRevision,
            authenticationState: record.authenticationState
        )
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
        if let runtime = runtimes[record.id] {
            await runtime.stop()
            runtimes[record.id] = nil
        }
        try await providers.forgetCredentials(for: removing)
        try storage.erase(record.id)
        try registry.remove(record.id)
        records[record.id] = nil
    }

    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
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
        await awaitChanges()
        lease?.release()
        lease = nil
    }

    func finishChange(_ id: ConnectedAccountID) {
        changing.remove(id)
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

    func makeRuntime(_ record: AccountRecord) throws -> AccountRuntime {
        let instanceID = UUID()
        return try AccountRuntime(
            record: record, storage: storage.open(record.id), factory: providers, instanceID: instanceID,
            onFault: { [weak self] fault in
                await self?.runtimeFailed(
                    record.id,
                    generation: record.credentialGeneration,
                    instanceID: instanceID,
                    fault: fault
                )
            }
        )
    }
}
