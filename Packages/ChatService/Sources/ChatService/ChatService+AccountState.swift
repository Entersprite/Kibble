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

    /// In list order: by position, then records without one by ID.
    func accountSummaries(_ context: ServiceSessionContext) -> [AccountSummary] {
        records.values.sorted {
            ($0.position ?? .max, $0.id.rawValue) < ($1.position ?? .max, $1.id.rawValue)
        }.compactMap { record in
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
            policyRevision: policyRevisions[record.id], runtimeID: runtimes[record.id]?.instanceID,
            profile: record.profile
        )
    }

    /// The listed accounts first, in the given order, then the rest in their
    /// current order. A refused save leaves earlier positions written; listing
    /// stays well defined because ties fall back to the account ID.
    func reorderAccounts(
        _ order: [ConnectedAccountID], context: ServiceSessionContext
    ) throws -> [AccountSummary] {
        guard context.canLinkAccounts else { throw ServiceFailure.notAuthorized }
        guard order.count <= ReorderAccounts.maximumCount, Set(order).count == order.count
        else { throw ServiceFailure.invalidRequest }
        let current = accountSummaries(context).map(\.id)
        guard Set(order).isSubset(of: current) else { throw ServiceFailure.accountNotFound }
        let arranged = order + current.filter { !order.contains($0) }
        for (position, id) in arranged.enumerated() {
            guard var record = records[id], record.position != position else { continue }
            record.position = position
            try registry.save(record)
            records[id] = record
        }
        accountStateChanged()
        return accountSummaries(context)
    }

    /// The next list position: after every current account.
    func nextAccountPosition() -> Int {
        (records.values.compactMap(\.position).max() ?? -1) + 1
    }

    /// Records saved before ordering existed keep their old relative order
    /// (by ID) and go after any positioned ones. A record that cannot be saved
    /// keeps no position and still lists last, so this never blocks startup.
    func assignMissingPositions() {
        let unplaced = records.values.filter { $0.position == nil && !$0.isRemoving }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        for var record in unplaced {
            record.position = nextAccountPosition()
            guard (try? registry.save(record)) != nil else { continue }
            records[record.id] = record
        }
    }

    /// Keeps the provider's latest own identity. Only the current runtime of the
    /// current binding may change it, and an unchanged profile writes nothing.
    /// What a report leaves out keeps its known value: identification by id
    /// alone must not erase a name already learned.
    func runtimeProfileChanged(
        _ id: ConnectedAccountID, revision: ServiceAccountRevision, instanceID: UUID, profile: AccountProfile
    ) {
        guard !shuttingDown, var record = records[id], record.currentRevision == revision,
              !record.isRemoving, runtimes[id]?.instanceID == instanceID else { return }
        let known = record.profile
        let merged = AccountProfile(
            displayName: profile.displayName ?? known?.displayName,
            email: profile.email ?? known?.email,
            organization: profile.organization == .unstated ? known?.organization ?? .unstated
                : profile.organization
        )
        guard merged != known else { return }
        record.profile = merged
        do {
            try registry.save(record)
        } catch {
            // Display metadata only: the previous profile stays, and the next
            // identification tries again.
            return
        }
        records[id] = record
        accountStateChanged()
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
            onProfile: { [weak self] profile in
                await self?.runtimeProfileChanged(
                    record.id, revision: record.currentRevision, instanceID: instanceID, profile: profile
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
