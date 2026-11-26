import Foundation
import Synchronization

/// Whether a person is waiting for provider work. History reads of one
/// conversation share one, so a request that joins a queued background read
/// raises that read instead of waiting behind other background work.
final class WorkUrgency: Sendable {
    private let waiters: Mutex<Int>

    init(interactive: Bool = false) {
        waiters = Mutex(interactive ? 1 : 0)
    }

    var isInteractive: Bool {
        waiters.withLock { $0 > 0 }
    }

    func raise() {
        waiters.withLock { $0 += 1 }
    }

    func lower() {
        waiters.withLock { $0 = max(0, $0 - 1) }
    }
}

/// Admission across accounts. Canceled queued startup work never constructs
/// a provider; an admitted noncooperative operation keeps its slot until it settles.
///
/// Interactive work, which a person is waiting for, goes ahead of queued
/// background work; each kind is first come, first served. It may also use
/// `interactiveReserve` slots, per owner and overall, that background work
/// never holds. A queued background waiter that could have started is passed
/// over at most `maximumBypasses` times, so background work cannot starve.
actor AccountWorkAdmission {
    private struct Waiter {
        let owner: UUID
        let urgency: WorkUrgency?
        let continuation: CheckedContinuation<Void, any Error>
        var bypasses = 0
    }

    private struct Admitted {
        let owner: UUID
        let background: Bool
    }

    private struct Candidate {
        let index: Int
        let interactive: Bool
    }

    private let limit: Int
    private let perOwnerLimit: Int
    private let interactiveReserve: Int
    private let maximumBypasses: Int
    private var active: [UUID: Admitted] = [:]
    private var ownerCounts: [UUID: Int] = [:]
    private var backgroundCounts: [UUID: Int] = [:]
    private var backgroundCount = 0
    private var order: [UUID] = []
    private var waiting: [UUID: Waiter] = [:]
    var activeCount: Int {
        active.count
    }

    var waitingCount: Int {
        waiting.count
    }

    init(limit: Int, perOwnerLimit: Int? = nil, interactiveReserve: Int = 0, maximumBypasses: Int = 4) {
        self.limit = max(1, limit)
        self.perOwnerLimit = max(1, perOwnerLimit ?? limit)
        self.interactiveReserve = max(0, min(interactiveReserve, self.perOwnerLimit - 1, self.limit - 1))
        self.maximumBypasses = max(0, maximumBypasses)
    }

    func acquire(
        _ id: UUID, owner: UUID? = nil, cancellable: Bool = true, urgency: WorkUrgency? = nil
    ) async throws {
        if cancellable {
            try Task.checkCancellation()
        }
        let owner = owner ?? id
        let interactive = urgency?.isInteractive == true
        // Queued work whose urgency was raised since it last checked goes first.
        admitWaiters()
        if admits(owner, interactive: interactive) {
            admit(id, owner: owner, interactive: interactive)
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
                waiting[id] = Waiter(owner: owner, urgency: urgency, continuation: continuation)
            }
        } onCancel: {
            if cancellable {
                Task { await self.cancel(id) }
            }
        }
    }

    func release(_ id: UUID) {
        guard let admitted = active.removeValue(forKey: id) else { return }
        ownerCounts[admitted.owner] = Self.decremented(ownerCounts[admitted.owner])
        if admitted.background {
            backgroundCounts[admitted.owner] = Self.decremented(backgroundCounts[admitted.owner])
            backgroundCount -= 1
        }
        admitWaiters()
    }

    /// Queued work may have become interactive: admit whatever can start now.
    func urgencyRaised() {
        admitWaiters()
    }

    /// Mandatory cleanup remains admitted even if its caller was canceled.
    func cleanup(_ operation: @Sendable () async -> Void) async {
        let id = UUID()
        try? await acquire(id, cancellable: false)
        await operation()
        release(id)
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiting.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func admits(_ owner: UUID, interactive: Bool) -> Bool {
        guard active.count < limit, ownerCounts[owner, default: 0] < perOwnerLimit else { return false }
        return interactive || backgroundCount < limit - interactiveReserve
            && backgroundCounts[owner, default: 0] < perOwnerLimit - interactiveReserve
    }

    private func admit(_ id: UUID, owner: UUID, interactive: Bool) {
        active[id] = Admitted(owner: owner, background: !interactive)
        ownerCounts[owner, default: 0] += 1
        if !interactive {
            backgroundCounts[owner, default: 0] += 1
            backgroundCount += 1
        }
    }

    private func admitWaiters() {
        while let next = nextWaiter() {
            let id = order.remove(at: next.index)
            guard let waiter = waiting.removeValue(forKey: id) else { continue }
            admit(id, owner: waiter.owner, interactive: next.interactive)
            waiter.continuation.resume()
        }
    }

    /// The first interactive waiter that can start, unless the first background
    /// waiter that can start was queued before it and has been passed over enough.
    private func nextWaiter() -> Candidate? {
        var urgent: Int?
        var background: Int?
        for (index, id) in order.enumerated() where urgent == nil || background == nil {
            guard let waiter = waiting[id] else { continue }
            let interactive = waiter.urgency?.isInteractive == true
            if interactive, urgent == nil, admits(waiter.owner, interactive: true) {
                urgent = index
            } else if !interactive, background == nil, admits(waiter.owner, interactive: false) {
                background = index
            }
        }
        guard let background else { return urgent.map { Candidate(index: $0, interactive: true) } }
        guard let urgent else { return Candidate(index: background, interactive: false) }
        if urgent < background {
            return Candidate(index: urgent, interactive: true)
        }
        let passed = order[background]
        guard let bypasses = waiting[passed]?.bypasses, bypasses < maximumBypasses else {
            return Candidate(index: background, interactive: false)
        }
        waiting[passed]?.bypasses = bypasses + 1
        return Candidate(index: urgent, interactive: true)
    }

    private static func decremented(_ count: Int?) -> Int? {
        guard let count, count > 1 else { return nil }
        return count - 1
    }
}
