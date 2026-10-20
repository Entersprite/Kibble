import ChatAPI
import ChatKit
import Foundation

struct RuntimeStatus: Sendable {
    let connection: ConnectionState
    let capabilities: Capabilities
}

struct RuntimeStatusEntry: Sendable {
    let instanceID: UUID
    let revision: ServiceAccountRevision
    let status: RuntimeStatus
}

struct AccountStateSubscriber {
    let context: ServiceSessionContext
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
}

extension ChatService {
    public func accountStates(_ bytes: Data, context: ServiceSessionContext) throws
        -> AsyncThrowingStream<Data, any Error> {
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        let request = try ServiceCodec.decode(ServiceRequest.self, from: bytes)
        _ = try ServiceAPIVersion.current.negotiated(with: request.header.version)
        _ = try request.decodePayload(WatchAccounts.self)
        guard restoredForSubscriptions, !shuttingDown else { throw ServiceFailure.overloaded }
        if let deadline = request.header.deadline, deadline <= Date() {
            throw ServiceFailure.deadlineExceeded
        }
        guard accountSubscribers.count < maximumAccountSubscriptions else { throw ServiceFailure.overloaded }
        let initial = try encodedAccountState(context)
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        accountSubscribers[id] = AccountStateSubscriber(context: context, continuation: continuation)
        continuation.yield(initial)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAccountSubscriber(id) }
        }
        return stream
    }

    private func removeAccountSubscriber(_ id: UUID) {
        accountSubscribers[id] = nil
    }

    func pendingLinks(_ context: ServiceSessionContext) -> [AccountLinkSummary] {
        guard context.canLinkAccounts else { return [] }
        return links.values.filter {
            $0.principalID == context.principalID && $0.deviceID == context.deviceID &&
                ($0.targetAccountID.map { context.allowsAccount($0) } ?? true) &&
                !["completed", "canceled", "alreadyConnected"].contains($0.phase)
        }.sorted { $0.id.rawValue < $1.id.rawValue }.map(\.summary)
    }

    func accountSummaries(_ context: ServiceSessionContext) -> [AccountSummary] {
        records.values.sorted { $0.id.rawValue < $1.id.rawValue }.compactMap { record in
            guard record.principalID == context.principalID, context.allowsAccount(record.id)
            else { return nil }
            return accountSummary(record)
        }
    }

    func accountSummary(_ record: AccountRecord) -> AccountSummary {
        let status = runtimeStatuses[record.id]
        let active = record.isEnabled && !record.isRemoving && record.authenticationState == nil &&
            status?.instanceID == runtimes[record.id]?.instanceID && status?.revision == record
            .currentRevision
        return AccountSummary(
            id: record.id, selfID: record.selfID, label: record.label,
            connection: active ? status?.status.connection ?? .idle : .disconnected(reason: nil, issue: nil),
            isEnabled: record.isEnabled, isReady: active, isRemoving: record.isRemoving,
            capabilities: active ? status?.status.capabilities ?? .init() : .init(),
            revision: record.currentRevision, authenticationState: record.authenticationState,
            policyRevision: policyRevisions[record.id], runtimeID: runtimes[record.id]?.instanceID
        )
    }

    func accountStateChanged() {
        for subscriber in accountSubscribers.values {
            do {
                try subscriber.continuation.yield(encodedAccountState(subscriber.context))
            } catch {
                subscriber.continuation.finish(throwing: error)
            }
        }
    }

    private func encodedAccountState(_ context: ServiceSessionContext) throws -> Data {
        let bytes = try ServiceCodec.encode(AccountStateSnapshot(
            accounts: accountSummaries(context), pendingLinks: pendingLinks(context)
        ))
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        return bytes
    }

    func runtimeStatusChanged(
        _ id: ConnectedAccountID, revision: ServiceAccountRevision, instanceID: UUID, status: RuntimeStatus
    ) {
        guard !shuttingDown, records[id]?.currentRevision == revision,
              runtimes[id]?.instanceID == instanceID else { return }
        runtimeStatuses[id] = RuntimeStatusEntry(instanceID: instanceID, revision: revision, status: status)
        accountStateChanged()
    }

    func makeRuntime(_ record: AccountRecord) throws -> AccountRuntime {
        let instanceID = UUID()
        let accountStorage = try storage.open(record.id)
        if let notificationHost {
            guard let outbox = accountStorage as? any ServiceNotificationStorage else {
                throw ServiceFailure.unsupportedOperation
            }
            try outbox.initializeNotifications(for: notificationHost.deviceID)
        }
        return try AccountRuntime(
            record: record, storage: accountStorage, factory: providers,
            policies: policies, instanceID: instanceID,
            notificationHost: notificationHost, notificationService: self.instanceID,
            callReservations: callReservations, providerStarts: providerStarts, providerStops: providerStops,
            providerWork: providerWork, callCleanupAdmission: callCleanupAdmission,
            transferStorage: transferFiles?.open(record.id), transferLimits: transferLimits,
            transferNow: transferNow,
            onStatus: { [weak self] status in
                await self?.runtimeStatusChanged(
                    record.id, revision: record.currentRevision, instanceID: instanceID, status: status
                )
            },
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
