import Foundation

/// FIFO admission across accounts. Canceled queued startup work never constructs
/// a provider; an admitted noncooperative operation keeps its slot until it settles.
actor AccountWorkAdmission {
    private let limit: Int
    private let perOwnerLimit: Int
    private var owners: [UUID: UUID] = [:]
    private var ownerCounts: [UUID: Int] = [:]
    private var active: Set<UUID> = []
    private var order: [UUID] = []
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var activeCount: Int {
        active.count
    }

    var waitingCount: Int {
        waiting.count
    }

    init(limit: Int, perOwnerLimit: Int? = nil) {
        self.limit = max(1, limit)
        self.perOwnerLimit = max(1, perOwnerLimit ?? limit)
    }

    func acquire(_ id: UUID, owner: UUID? = nil, cancellable: Bool = true) async throws {
        if cancellable {
            try Task.checkCancellation()
        }
        let owner = owner ?? id
        owners[id] = owner
        if active.count < limit, ownerCounts[owner, default: 0] < perOwnerLimit {
            active.insert(id)
            ownerCounts[owner, default: 0] += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                Void,
                any Error
            >) in
                if cancellable, Task.isCancelled {
                    owners[id] = nil
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
        if let owner = owners.removeValue(forKey: id) {
            let count = ownerCounts[owner, default: 1] - 1
            ownerCounts[owner] = count == 0 ? nil : count
        }
        guard let index = order.firstIndex(where: { id in
            guard let owner = owners[id] else { return false }
            return ownerCounts[owner, default: 0] < perOwnerLimit
        }) else { return }
        let next = order.remove(at: index)
        guard let continuation = waiting.removeValue(forKey: next), let owner = owners[next] else { return }
        active.insert(next)
        ownerCounts[owner, default: 0] += 1
        continuation.resume()
    }

    /// Mandatory cleanup remains admitted even if its caller was canceled.
    func cleanup(_ operation: @Sendable () async -> Void) async {
        let id = UUID()
        try? await acquire(id, cancellable: false)
        await operation()
        release(id)
    }

    private func cancel(_ id: UUID) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        owners[id] = nil
        continuation.resume(throwing: CancellationError())
        order.removeAll { $0 == id }
    }
}
