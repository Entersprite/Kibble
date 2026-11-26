import ChatAPI
import Foundation

/// Per-adapter admission: FIFO within each kind, alternating kinds when both
/// wait. Separate bounded queues leave room for uploads during image batches.
actor TransferWorkQueue {
    enum Kind: Sendable { case media, upload }
    private struct Waiter {
        let id: UUID
        let kind: Kind
        let continuation: CheckedContinuation<UUID, any Error>
    }

    private let maximumRunning: Int
    private let maximumQueuedMedia: Int
    private let maximumQueuedUploads: Int
    private(set) var active: [UUID: Kind] = [:]
    private var pending: [Waiter] = []
    private var next: Kind = .upload

    var queuedCount: Int {
        pending.count
    }

    init(maximumRunning: Int = 8, maximumQueuedMedia: Int = 56, maximumQueuedUploads: Int = 8) {
        self.maximumRunning = max(1, maximumRunning)
        self.maximumQueuedMedia = max(1, maximumQueuedMedia)
        self.maximumQueuedUploads = max(1, maximumQueuedUploads)
    }

    func acquire(_ kind: Kind) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let limit = kind == .media ? maximumQueuedMedia : maximumQueuedUploads
                guard pending.count(where: { $0.kind == kind }) < limit else {
                    continuation.resume(throwing: ServiceFailure.overloaded)
                    return
                }
                pending.append(Waiter(id: id, kind: kind, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard active.removeValue(forKey: id) != nil else { return }
        drain()
    }

    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func drain() {
        while active.count < maximumRunning, !pending.isEmpty {
            let index = pending.firstIndex(where: { $0.kind == next }) ?? 0
            let waiter = pending.remove(at: index)
            active[waiter.id] = waiter.kind
            next = waiter.kind == .media ? .upload : .media
            waiter.continuation.resume(returning: waiter.id)
        }
    }
}

extension ServiceBackend {
    func withTransferPermit<Value: Sendable>(
        _ kind: TransferWorkQueue.Kind, operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let permit = try await transferQueue.acquire(kind)
        let result: Result<Value, any Error>
        do {
            try Task.checkCancellation()
            result = try await .success(operation())
        } catch { result = .failure(error) }
        // Cancellation never releases a permit while its work still owns it.
        await transferQueue.release(permit)
        return try result.get()
    }
}
