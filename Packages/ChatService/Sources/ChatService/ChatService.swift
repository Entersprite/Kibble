import ChatAPI
import ChatKit
import Foundation

/// Account runtimes belong to this host, independently of client subscriptions.
public actor ChatService: ServiceEventEndpoint {
    private let registry: any AccountRegistry
    private let storage: any ServiceStorageFactory
    private let providers: any AccountProviderFactory
    private var records: [ConnectedAccountID: AccountRecord] = [:]
    private var runtimes: [ConnectedAccountID: AccountRuntime] = [:]
    private var changing: Set<ConnectedAccountID> = []
    private var restored = false
    private var shuttingDown = false

    public init(
        registry: any AccountRegistry,
        storage: any ServiceStorageFactory,
        providers: any AccountProviderFactory
    ) {
        self.registry = registry
        self.storage = storage
        self.providers = providers
    }

    public func restore() async throws {
        guard !restored else { return }
        let accounts = try registry.accounts()
        records = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        restored = true
        for record in accounts where record.isEnabled && !record.isRemoving {
            let runtime = try makeRuntime(record)
            runtimes[record.id] = runtime
            await runtime.start()
        }
    }

    /// Host-only admission after credential validation; no client DTO grants this authority.
    public func registerVerified(_ record: AccountRecord) async throws {
        guard restored, !shuttingDown, !record.isRemoving else { throw ServiceFailure.invalidRequest }
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
              let id = request.header.accountID, context.accounts.contains(id),
              let record = records[id], record.principalID == context.principalID,
              !record.isRemoving else { throw ServiceFailure.notAuthorized }
        guard record.isEnabled, !changing.contains(id), let runtime = runtimes[id] else {
            throw ServiceFailure.accountDisabled
        }
        return try await runtime.subscribe(after: payload.cursor)
    }

    private func route(_ request: ServiceRequest, context: ServiceSessionContext) async throws -> JSONValue {
        if request.operation == ListAccounts.operation {
            _ = try request.decodePayload(ListAccounts.self)
            var accounts: [AccountSummary] = []
            for record in records.values.sorted(by: { $0.id.rawValue < $1.id.rawValue })
                where record.principalID == context.principalID && context.accounts
                .contains(record.id) && !record.isRemoving {
                let runtime = runtimes[record.id]
                await accounts.append(AccountSummary(
                    id: record.id, selfID: record.selfID, label: record.label,
                    connection: runtime?.connection ?? .disconnected(reason: nil, issue: nil),
                    isEnabled: record.isEnabled, capabilities: runtime?.capabilities ?? .init()
                ))
            }
            return try ServiceCodec.value(accounts)
        }
        guard let id = request.header.accountID else { throw ServiceFailure.accountRequired }
        guard context.accounts.contains(id), let record = records[id],
              record.principalID == context.principalID,
              !record.isRemoving else { throw ServiceFailure.notAuthorized }
        switch request.operation {
        case SetAccountEnabled.operation:
            let payload = try request.decodePayload(SetAccountEnabled.self)
            return try await ServiceCodec.value(setEnabled(payload.enabled, record: record))
        case RemoveAccount.operation:
            _ = try request.decodePayload(RemoveAccount.self)
            try await remove(record)
            return try ServiceCodec.value(ServiceUnit())
        default:
            guard record.isEnabled, !changing.contains(id) else { throw ServiceFailure.accountDisabled }
            guard let runtime = runtimes[id] else { throw ServiceFailure.overloaded }
            return try await runtime.handle(request)
        }
    }

    private func setEnabled(_ enabled: Bool, record: AccountRecord) async throws -> AccountSummary {
        guard !changing.contains(record.id) else { throw ServiceFailure.overloaded }
        changing.insert(record.id)
        defer { changing.remove(record.id) }
        var record = record
        record.isEnabled = enabled
        try registry.save(record)
        records[record.id] = record
        if !enabled {
            if let runtime = runtimes[record.id] {
                await runtime.stop()
                runtimes[record.id] = nil
            }
        } else if runtimes[record.id] == nil {
            let runtime = try makeRuntime(record)
            runtimes[record.id] = runtime
            await runtime.start()
        }
        return AccountSummary(
            id: record.id,
            selfID: record.selfID,
            label: record.label,
            connection: .idle,
            isEnabled: enabled
        )
    }

    private func remove(_ record: AccountRecord) async throws {
        guard !changing.contains(record.id) else { throw ServiceFailure.overloaded }
        changing.insert(record.id)
        defer { changing.remove(record.id) }
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
        let all = Array(runtimes.values)
        await withTaskGroup(of: Void.self) { group in
            for runtime in all {
                group.addTask { await runtime.stop() }
            }
        }
        runtimes.removeAll()
    }

    public var activeRuntimeCount: Int {
        runtimes.count
    }

    private func makeRuntime(_ record: AccountRecord) throws -> AccountRuntime {
        try AccountRuntime(record: record, storage: storage.open(record.id), factory: providers)
    }
}
