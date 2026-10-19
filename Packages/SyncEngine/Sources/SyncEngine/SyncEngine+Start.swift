import ChatKit
import Foundation

public extension SyncEngine {
    /// Clears what was only true last time, starts consuming, then connects.
    ///
    /// Consuming starts *before* connecting so that nothing emitted during
    /// connection can be missed. Calling this twice does nothing the second
    /// time.
    func start() async throws {
        guard consumer == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let generation = managementGeneration
        try store.apply([.clearEphemeralState])
        activityRunning = true
        if let checkpointed = backend as? any CheckpointedChatBackend {
            let deliveries = try await checkpointed
                .useCheckpointedDeliveries(after: store.replicaCheckpoint())
            guard generation == managementGeneration else { throw CancellationError() }
            consumer = Task { [weak self] in
                for await delivery in deliveries {
                    guard !Task.isCancelled, let self else { return }
                    let applied = await handleDelivery(delivery)
                    if let checkpoint = delivery.checkpoint {
                        await checkpointed.acknowledge(checkpoint, applied: applied)
                    }
                }
            }
        } else {
            let stream = backend.events
            consumer = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event)
                }
            }
        }
        try await backend.connect()
    }
}
