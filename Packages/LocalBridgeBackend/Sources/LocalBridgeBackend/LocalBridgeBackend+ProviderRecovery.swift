import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    /// How many conversations a rebase may withdraw history confidence from
    /// one by one; past it the whole account's goes, in one cheaper write.
    static let scopedInvalidationLimit = 512

    func requestProviderRecovery() {
        guard delivery.running, isConnected else { return }
        delivery.recovering = true
        delivery.blocksAll = true
        delivery.blocksUser = true
        delivery.recoveryRequested = true
        guard delivery.recovery == nil else { return }
        let generation = directoryGeneration
        let epoch = delivery.epoch
        delivery.rebasedRecovery = false
        delivery.notificationFloor = delivery.cursor.baseline ? Date()
            .addingTimeInterval(-120) : .distantFuture
        emit(.gap(scope: .everything, reason: "Provider revision recovery started."))
        delivery.recovery = Task { [weak self] in await self?.recoverProvider(
            generation: generation,
            epoch: epoch
        ) }
    }

    private func recoverProvider(generation: Int, epoch: UUID) async {
        defer {
            if epoch == delivery.epoch {
                delivery.recovery = nil
                delivery.recovering = false
            }
        }
        do {
            await selfIdentification?.value
            try requireRecoverySession(generation)
            guard let me = calendarPoll.me
            else { throw ChatError.decoding("The account identity is unavailable.") }
            guard delivery.cursor.identity == nil || delivery.cursor.identity == me.rawValue else {
                throw ChatError.sessionExpired
            }
            repeat {
                delivery.recoveryRequested = false
                try await recoveryRound(identity: me.rawValue, generation: generation)
                try requireRecoverySession(generation)
            } while delivery.recoveryRequested
            delivery.recoveryIncomplete = false
            delivery.recoveryFailures = 0
            delivery.recovering = false
            flushRecoveredEvents()
            try await submitProviderBatch(.init(events: [.resourceSyncChanged(.init(
                resource: .history,
                phase: .ready
            ))]))
        } catch {
            guard !Task.isCancelled, generation == directoryGeneration, delivery.running else { return }
            emit(.resourceSyncChanged(.init(
                resource: .history, phase: .failed,
                error: error as? ChatError ?? .unknown("Provider recovery could not complete.")
            )))
            delivery.recoveryIncomplete = true
            delivery.recovering = false
            delivery.recoveryRequested = false
            flushRecoveredEvents()
            if case .decoding = error as? ChatError {
                return
            }
            if error as? ChatError != .sessionExpired {
                scheduleProviderRecoveryRetry(
                    epoch: epoch,
                    error: error
                )
            }
        }
    }

    private func recoveryRound(identity: String, generation: Int) async throws {
        try await submitProviderBatch(.init(
            events: [.resourceSyncChanged(.init(resource: .history, phase: .catchingUp))],
            directoryReadBegan: true
        ))
        let result = try await readProviderDirectory()
        try requireRecoverySession(generation)
        let revisions = Dictionary(result.world.worldItems.compactMap { item -> (String, Int64)? in
            guard WorldMapping.isVisible(item), item.groupRevision.timestamp > 0,
                  let id = ChannelEventMapping.conversationID(item.groupID) else { return nil }
            return (id.rawValue, item.groupRevision.timestamp)
        }, uniquingKeysWith: max)
        let changed = revisions.filter { delivery.cursor.groups[$0.key, default: 0] < $0.value }
        let reset = !delivery.cursor.baseline || changed.count > 64
        // A rebase from an established baseline skips the changed groups'
        // catch-up, so only their history is unknown; without a baseline,
        // or past a bound, every conversation's is.
        let invalidated: [Conversation.ID] = reset && delivery.cursor.baseline
            && changed.count <= Self.scopedInvalidationLimit
            ? changed.keys.sorted().map { Conversation.ID($0) } : []
        delivery.overflowed = false
        var patch = ProviderCursorPatch(identity: identity, baseline: true)
        if reset {
            delivery.rebasedRecovery = true; patch.groups = revisions; patch.user = result.world.userRevision
                .timestamp; patch.rebase = true
        }
        try await submitProviderBatch(.init(
            events: invalidated.isEmpty ? [] : [.conversationHistoryInvalidated(invalidated)],
            directory: result.snapshot,
            invalidatesHistory: reset && invalidated.isEmpty,
            patch: patch
        ))
        delivery.directory = result.snapshot
        delivery.blocksAll = false
        delivery.blockedGroups = reset ? [] : Set(changed.keys)
        delivery.blocksUser = !reset
        flushRecoveredEvents()
        if reset {
            delivery.reactionGroups.removeAll(); delivery.deferredRevisions.removeAll()
            return
        }
        try await recoverUser(through: result.world.userRevision.timestamp, generation: generation)
        delivery.blocksUser = false
        flushRecoveredEvents()
        try await recoverChangedGroups(result.world.worldItems, generation: generation)
    }

    private func recoverChangedGroups(_ items: [WorldItemLite], generation: Int) async throws {
        let ordered = items
            .sorted { $0.groupRevision.timestamp > $1.groupRevision.timestamp }
        for item in ordered where WorldMapping.isVisible(item) {
            guard item.groupRevision.timestamp > 0,
                  let id = ChannelEventMapping.conversationID(item.groupID) else { continue }
            let before = delivery.cursor.groups[id.rawValue] ?? 0
            guard before < item.groupRevision.timestamp else { continue }
            if before == 0 {
                // No saved position for this conversation: its history alone is unknown.
                try await submitProviderBatch(.init(
                    events: [.conversationHistoryInvalidated([id])],
                    patch: .init(groups: [id.rawValue: item.groupRevision.timestamp])
                ))
            } else {
                try await recoverGroup(item, id: id, generation: generation)
            }
            delivery.reactionGroups = delivery.reactionGroups.filter { $0.value != id.rawValue }
            delivery.deferredRevisions[id.rawValue] = nil
            delivery.blockedGroups.remove(id.rawValue)
            flushRecoveredEvents()
        }
    }

    private func flushRecoveredEvents() {
        let buffered = delivery.buffered
        delivery.buffered.removeAll(); delivery.bufferedBytes = 0
        for event in buffered {
            if isBlockedByRecovery(event) {
                delivery.buffered.append(event)
                delivery.bufferedBytes += event.bodies
                    .reduce(0) { $0 + ((try? $1.value.jsonData().count) ?? 0) }
                continue
            }
            let mapped = ChannelEventMapping.chatEvents(from: event)
            let patch = cursorPatch(for: event, events: mapped)
            let duplicate = event.revision != nil && !delivery.recoveryIncomplete && !delivery
                .rebasedRecovery && (
                    patch.user.map { $0 < delivery.cursor.user } ??
                        (!patch.groups.isEmpty && patch.groups.allSatisfy { $0.value < delivery.cursor.groups[
                            $0.key,
                            default: 0
                        ] })
                )
            if !duplicate {
                receiveCheckpointedEvent(event)
            }
        }
    }

    private func scheduleProviderRecoveryRetry(epoch: UUID, error: any Error) {
        guard delivery.retry == nil else { return }
        delivery.recoveryFailures = min(64, delivery.recoveryFailures + 1)
        let attempt = delivery.recoveryFailures
        let retryAfter: Duration? = if case let .rateLimited(delay) = error as? ChatError {
            delay
        } else {
            nil
        }
        delivery.retry = Task { [weak self] in
            do {
                if let retryAfter {
                    try await Task.sleep(for: retryAfter)
                } else {
                    try await RetryPolicy.default.waitBeforeRetry(attempt: attempt)
                }
            } catch { return }
            await self?.retryProviderRecovery(epoch: epoch)
        }
    }

    private func retryProviderRecovery(epoch: UUID) {
        guard delivery.running, delivery.epoch == epoch else { return }
        delivery.retry = nil
        requestProviderRecovery()
    }

    func requireRecoverySession(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isConnected, delivery.running,
              directoryGeneration == generation else { throw CancellationError() }
    }
}
