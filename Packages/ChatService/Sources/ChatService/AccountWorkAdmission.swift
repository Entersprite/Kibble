import Foundation

/// FIFO admission across accounts. Canceled queued startup work never constructs
/// a provider; an admitted noncooperative operation keeps its slot until it settles.
actor AccountWorkAdmission {
    private let limit: Int
    private var active: Set<UUID> = []
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var activeCount: Int {
        active.count
    }

    var waitingCount: Int {
        waiting.count
    }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(_ id: UUID, cancellable: Bool = true) async throws {
        if cancellable {
            try Task.checkCancellation()
        }
        if active.count < limit {
            active.insert(id)
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                Void,
                any Error
            >) in
                if cancellable, Task.isCancelled {
                    continuation.resume(throwing: CancellationError()); return
                }
                order.append(id)
                waiting[id] = continuation
            }
        } onCancel: {
            if cancellable {
                Task { await self.cancel(id) }
            }
        }
    }

    func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        while !order.isEmpty {
            let next = order.removeFirst()
            guard let continuation = waiting.removeValue(forKey: next) else { continue }
            active.insert(next)
            continuation.resume()
            return
        }
    }

    /// Mandatory cleanup remains admitted even if its caller was canceled.
    func cleanup(_ operation: @Sendable () async -> Void) async {
        let id = UUID()
        try? await acquire(id, cancellable: false)
        await operation()
        release(id)
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
        order.removeAll { $0 == id }
    }
}
