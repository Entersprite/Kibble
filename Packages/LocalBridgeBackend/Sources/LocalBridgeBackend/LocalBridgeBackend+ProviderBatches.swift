import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend: ProviderCheckpointBackend {
    public func usesProviderCheckpoints() -> Bool {
        true
    }

    public func connect(resumingProviderCheckpoint checkpoint: Data?) async throws {
        delivery.epoch = UUID()
        delivery.running = true
        delivery.checkpoint = checkpoint
        delivery.cursor = GoogleProviderCursor(data: checkpoint)
        delivery.recovering = true
        try await connect()
        requestProviderRecovery()
    }

    public func acknowledgeProviderBatch(_ id: String) {
        guard delivery.batchID == id else { return }
        let waiter = delivery.acknowledgement
        delivery.acknowledgement = nil
        waiter?.resume(returning: true)
    }
}

extension LocalBridgeBackend {
    func enqueueProviderBatch(_ pending: PendingProviderBatch) {
        guard delivery.running, delivery.queue.count < 128 else {
            pending.completion?.resume(returning: false)
            delivery.recoveryRequested = delivery.running
            delivery.recovering = delivery.running
            delivery.blocksAll = true
            delivery.overflowed = true
            return
        }
        delivery.queue.append(pending)
        guard delivery.pump == nil else { return }
        let epoch = delivery.epoch
        delivery.pump = Task { [weak self] in await self?.pumpProviderBatches(epoch: epoch) }
    }

    func submitProviderBatch(_ pending: PendingProviderBatch) async throws {
        try Task.checkCancellation()
        let accepted = await withCheckedContinuation { continuation in
            var pending = pending
            pending.completion = continuation
            enqueueProviderBatch(pending)
        }
        guard accepted, !Task.isCancelled else { throw CancellationError() }
    }

    private func pumpProviderBatches(epoch: UUID) async {
        defer {
            if epoch == delivery.epoch {
                delivery.pump = nil
            }
        }
        while delivery.running, !Task.isCancelled, epoch == delivery.epoch, !delivery.queue.isEmpty {
            let pending = delivery.queue.removeFirst()
            var next = delivery.cursor
            next.apply(pending.patch)
            do {
                let checkpoint = try next.encoded()
                let batch = ProviderEventBatch(
                    id: UUID().uuidString, events: pending.events, directory: pending.directory,
                    invalidatesHistory: pending.invalidatesHistory,
                    directoryReadBegan: pending.directoryReadBegan,
                    previousCheckpoint: delivery.checkpoint,
                    checkpoint: checkpoint, isLive: pending.live
                )
                let accepted = await awaitProviderAcknowledgement(batch)
                guard accepted, delivery.running, epoch == delivery.epoch else {
                    pending.completion?.resume(returning: false)
                    for queued in delivery.queue {
                        queued.completion?.resume(returning: false)
                    }
                    delivery.queue.removeAll()
                    return
                }
                delivery.cursor = next
                delivery.checkpoint = checkpoint
                pending.completion?.resume(returning: true)
            } catch {
                pending.completion?.resume(returning: false)
                delivery.overflowed = true
                delivery.recoveryRequested = true
            }
        }
        if delivery.recoveryRequested, delivery.recovery == nil,
           delivery.running {
            requestProviderRecovery()
        }
    }

    private func awaitProviderAcknowledgement(_ batch: ProviderEventBatch) async -> Bool {
        delivery.batchID = batch.id
        return await withCheckedContinuation { waiter in
            delivery.acknowledgement = waiter
            switch providerBatchContinuation.yield(batch) {
            case .enqueued: break
            case .dropped, .terminated:
                delivery.acknowledgement = nil
                waiter.resume(returning: false)
            @unknown default:
                delivery.acknowledgement = nil
                waiter.resume(returning: false)
            }
        }
    }

    func stopProviderBatches() -> [Task<Void, Never>] {
        delivery.running = false
        delivery.epoch = UUID()
        let jobs = [delivery.pump, delivery.recovery, delivery.retry].compactMap(\.self)
        delivery.retry = nil
        delivery.pump = nil
        delivery.recovery = nil
        delivery.recovering = false
        for job in jobs {
            job.cancel()
        }
        delivery.acknowledgement?.resume(returning: false)
        delivery.acknowledgement = nil
        for pending in delivery.queue {
            pending.completion?.resume(returning: false)
        }
        delivery.queue.removeAll()
        delivery.buffered.removeAll()
        delivery.bufferedBytes = 0
        return jobs
    }
}
