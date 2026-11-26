import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func consumeProviderBatches(
        from source: any ProviderCheckpointBackend, epoch: UUID
    ) async {
        for await batch in source.providerEventBatches {
            guard !Task.isCancelled, epoch == currentEpoch, !stopped,
                  !quarantinedForSubscription else { return }
            await ingestProviderBatch(batch, from: source, epoch: epoch)
        }
    }

    private func ingestProviderBatch(
        _ batch: ProviderEventBatch, from source: any ProviderCheckpointBackend, epoch: UUID
    ) async {
        guard let storage = storage as? any ServiceProviderCheckpointStorage else {
            await quarantine(.storage); return
        }
        do {
            try Self.validateProviderBatchBounds(batch)
            let baseline = batch.directoryReadBegan ? try storage.conversations() : nil
            let events = try mergedProviderEvents(batch)
            if events.contains(where: rejectsProviderEvent) {
                await quarantine(.authentication); return
            }
            for event in events {
                invalidateQueries(for: event)
                invalidateCallFacts(for: event)
            }
            let page = try storage.appendProviderBatch(batch, canonicalEvents: events)
            for item in page.events {
                providerEventCommitted(item.event)
            }
            providerDirectoryCommitted(batch, baseline: baseline)
            if !page.events.isEmpty {
                try publish(page)
            }
            await source.acknowledgeProviderBatch(batch.id)
            guard epoch == currentEpoch, !stopped, !quarantinedForSubscription else { return }
            for item in page.events {
                await scheduleEffects(for: item.event)
            }
            if page.events.contains(where: { Self.changesProviderConnection($0.event) }) {
                await publishProviderStatus()
            }
        } catch { await quarantine(.storage) }
    }

    private func providerDirectoryCommitted(_ batch: ProviderEventBatch, baseline: [Conversation]?) {
        if let baseline {
            reads.providerDirectoryBaseline = baseline
        }
        if batch.directory != nil {
            reads.providerDirectoryBaseline = nil
            reads.directoryCompletedAt = now()
        }
    }

    private static func validateProviderBatchBounds(_ batch: ProviderEventBatch) throws {
        guard batch.events.count <= 256, (batch.directory?.conversations.count ?? 0) <= 4096,
              (batch.directory?.removedIDs.count ?? 0) <= 4096,
              (batch.previousCheckpoint?.count ?? 0) <= 512 * 1024,
              (batch.checkpoint?.count ?? 0) <= 512 * 1024 else { throw ServiceFailure.frameTooLarge }
    }

    private func mergedProviderEvents(_ batch: ProviderEventBatch) throws -> [ChatEvent] {
        var events = batch.events
        if batch.invalidatesHistory {
            events.insert(.historyInvalidated, at: 0)
        }
        if let snapshot = batch.directory {
            let current = try storage.conversations()
            let merged = snapshot.merging(
                current: current,
                baseline: reads.providerDirectoryBaseline ?? current
            )
            if Set(merged) != Set(current) {
                events.insert(.conversationsChanged(merged), at: 0)
            }
        }
        return events
    }

    private static func changesProviderConnection(_ event: ChatEvent) -> Bool {
        if case .connectionStateChanged = event {
            return true
        }
        return false
    }

    private func rejectsProviderEvent(_ event: ChatEvent) -> Bool {
        switch event {
        case .backendError(.notAuthenticated), .backendError(.sessionExpired): true
        case let .resourceSyncChanged(status): status.error == .sessionExpired
        case let .selfIdentified(member): member.id != record.selfID
        default: false
        }
    }

    private func providerEventCommitted(_ event: ChatEvent) {
        callDirectoryChanged(by: event)
        invalidateMediaQueries(for: event)
        if !SyncReducer.reduce(event).effects.isEmpty {
            notificationsChanged()
        }
        if case let .connectionStateChanged(state) = event {
            setProviderConnection(state)
        }
        if case let .resourceSyncChanged(status) = event {
            resourceSyncCommitted(status)
        }
    }
}
