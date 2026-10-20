import ChatAPI
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AccountAdmissionTests {
    @Test func queuedAccountsAdvanceInOrderAndCanceledStartupNeverTakesASlot() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let first = UUID(); let canceled = UUID(); let next = UUID()
        try await admission.acquire(first)
        let discarded = Task { try await admission.acquire(canceled) }
        try await capacityEventually { await admission.waitingCount == 1 }
        let pending = Task { try await admission.acquire(next) }
        try await capacityEventually { await admission.waitingCount == 2 }
        discarded.cancel()
        await #expect(throws: CancellationError.self) { try await discarded.value }
        #expect(await admission.activeCount == 1)
        await admission.release(first)
        try await pending.value
        #expect(await admission.activeCount == 1)
        #expect(await admission.waitingCount == 0)
        await admission.release(first)
        #expect(await admission.activeCount == 1)
        await admission.release(next)
        #expect(await admission.activeCount == 0)
    }

    @Test func cancelingMandatoryCleanupCannotBypassItsBudgetOrSkipTheCleanup() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let occupied = UUID()
        try await admission.acquire(occupied)
        let evidence = AdmissionEvidence()
        let cleanup = Task { await admission.cleanup { await evidence.record() } }
        try await capacityEventually { await admission.waitingCount == 1 }
        cleanup.cancel()
        #expect(await !evidence.completed)
        #expect(await admission.waitingCount == 1)
        await admission.release(occupied)
        await cleanup.value
        #expect(await evidence.completed)
        #expect(await admission.activeCount == 0)
    }
}

private actor AdmissionEvidence {
    private(set) var completed = false
    func record() {
        completed = true
    }
}

func capacityEventually(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ServiceFailure.deadlineExceeded
}
