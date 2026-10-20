import ChatAPI
import ChatKit
import Foundation

struct PendingAcknowledgement {
    let checkpoint: ReplicaCheckpoint
    let generation: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

struct ProjectionWaiter {
    let checkpoint: ServiceCursor
    let continuation: CheckedContinuation<Void, any Error>
    let timeout: Task<Void, Never>
}

extension ServiceBackend {
    /// Queue pressure is a journal replay request. Keep the current committed
    /// cursor and only report unavailable if replay itself fails.
    func subscriptionFailure(_ error: any Error, generation: UUID) async -> (any Error)? {
        guard checkpointed, error as? ServiceFailure == .resynchronizationRequired else { return error }
        do {
            try await catchUp(generation: generation)
            return nil
        } catch {
            return error
        }
    }

    func projected<Value: Sendable>(_ query: () async throws -> Value) async throws -> Value {
        for _ in 0 ..< 3 {
            let generation = connectionGeneration
            let snapshot = resynchronization
            let value = try await query()
            if !checkpointed {
                return value
            }
            guard generation == connectionGeneration, consumer != nil else { throw CancellationError() }
            let position = try await call(GetProjectionCheckpoint())
            try await awaitProjection(position)
            guard generation == connectionGeneration else { throw CancellationError() }
            if snapshot == resynchronization {
                return value
            }
        }
        throw ServiceFailure.overloaded
    }

    private func awaitProjection(_ position: ServiceCursor) async throws {
        guard position.accountID == accountID else { throw ServiceFailure.invalidResponse }
        if let cursor, cursor.streamID == position.streamID, cursor.sequence >= position.sequence {
            return
        }
        guard projectionWaiters.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.finishProjectionWaiter(id, error: ServiceFailure.deadlineExceeded)
                }
                projectionWaiters[id] = ProjectionWaiter(
                    checkpoint: position, continuation: continuation, timeout: timeout
                )
            }
        } onCancel: {
            Task { await self.finishProjectionWaiter(id, error: CancellationError()) }
        }
    }

    func advanceProjectionWaiters() {
        guard let cursor else { return }
        for (id, waiter) in projectionWaiters {
            if waiter.checkpoint.streamID != cursor.streamID {
                finishProjectionWaiter(id, error: ServiceFailure.invalidResponse)
            } else if cursor.sequence >= waiter.checkpoint.sequence {
                projectionWaiters[id] = nil
                waiter.timeout.cancel()
                waiter.continuation.resume()
            }
        }
    }

    func failProjectionWaiters(_ error: any Error) {
        for id in Array(projectionWaiters.keys) {
            finishProjectionWaiter(id, error: error)
        }
    }

    private func finishProjectionWaiter(_ id: UUID, error: any Error) {
        guard let waiter = projectionWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
