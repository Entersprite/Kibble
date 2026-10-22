import Foundation
import Testing
@testable import ChatService

/// Work a person is waiting for goes ahead of background provider work and
/// has slots background work never holds, without starving background work.
@Suite(.timeLimit(.minutes(1)))
struct InteractiveAdmissionTests {
    @Test func backgroundWorkLeavesTheReservedSlotForInteractiveWork() async throws {
        let admission = AccountWorkAdmission(limit: 16, perOwnerLimit: 4, interactiveReserve: 1)
        let owner = UUID()
        let log = AdmissionLog()
        let background = (0 ..< 3).map { _ in UUID() }
        for id in background {
            try await admission.acquire(id, owner: owner)
        }
        let queued = UUID()
        let waiting = queue(admission, queued, owner: owner, log: log)
        try await capacityEventually { await admission.waitingCount == 1 }
        let urgent = UUID()
        try await admission.acquire(urgent, owner: owner, urgency: WorkUrgency(interactive: true))
        #expect(await admission.activeCount == 4)
        #expect(await admission.waitingCount == 1)
        // The queued background work starts as soon as background work finishes.
        await admission.release(background[0])
        try await waiting.value
        #expect(await log.entries == [queued])
        for id in background.dropFirst() + [urgent, queued] {
            await admission.release(id)
        }
        #expect(await admission.activeCount == 0)
    }

    @Test func theReserveAlsoHoldsAcrossOwners() async throws {
        let admission = AccountWorkAdmission(limit: 4, perOwnerLimit: 4, interactiveReserve: 1)
        let log = AdmissionLog()
        let background = (0 ..< 3).map { _ in UUID() }
        for id in background {
            try await admission.acquire(id)
        }
        let queued = UUID()
        let waiting = queue(admission, queued, log: log)
        try await capacityEventually { await admission.waitingCount == 1 }
        let urgent = UUID()
        try await admission.acquire(urgent, urgency: WorkUrgency(interactive: true))
        #expect(await admission.activeCount == 4)
        await admission.release(urgent)
        // The freed slot is the reserve, which background work never takes.
        #expect(await admission.waitingCount == 1)
        await admission.release(background[0])
        try await waiting.value
        for id in background.dropFirst() + [queued] {
            await admission.release(id)
        }
        #expect(await admission.activeCount == 0)
    }

    @Test func queuedInteractiveWorkGoesAheadOfEarlierBackgroundWork() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let log = AdmissionLog()
        let first = UUID(); let background = UUID(); let urgent = UUID(); let later = UUID()
        try await admission.acquire(first)
        var tasks: [Task<Void, any Error>] = []
        for (id, urgency) in [
            (background, nil),
            (urgent, WorkUrgency(interactive: true)),
            (later, WorkUrgency(interactive: true))
        ] {
            tasks.append(queue(admission, id, urgency: urgency, log: log))
            let count = tasks.count
            try await capacityEventually { await admission.waitingCount == count }
        }
        try await drain(admission, from: first, expecting: 3, log: log)
        #expect(await log.entries == [urgent, later, background])
        for task in tasks {
            try await task.value
        }
    }

    /// Interactive work queued first is not overtaken by background work
    /// queued after it.
    @Test func earlierInteractiveWorkIsNotOvertakenByLaterBackgroundWork() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let log = AdmissionLog()
        let first = UUID(); let urgent = UUID(); let background = UUID()
        try await admission.acquire(first)
        var tasks = [queue(admission, urgent, urgency: WorkUrgency(interactive: true), log: log)]
        try await capacityEventually { await admission.waitingCount == 1 }
        tasks.append(queue(admission, background, log: log))
        try await capacityEventually { await admission.waitingCount == 2 }
        try await drain(admission, from: first, expecting: 2, log: log)
        #expect(await log.entries == [urgent, background])
        for task in tasks {
            try await task.value
        }
    }

    /// Being overtaken by interactive work queued ahead of it does not count
    /// against background work's bypass bound: only later work passes it over.
    @Test func earlierInteractiveWorkDoesNotUseUpTheBypassBound() async throws {
        let admission = AccountWorkAdmission(limit: 1, maximumBypasses: 1)
        let log = AdmissionLog()
        let first = UUID(); let earlier = UUID(); let background = UUID(); let later = UUID()
        try await admission.acquire(first)
        var tasks: [Task<Void, any Error>] = []
        for (id, urgency) in [
            (earlier, WorkUrgency(interactive: true)),
            (background, nil),
            (later, WorkUrgency(interactive: true))
        ] {
            tasks.append(queue(admission, id, urgency: urgency, log: log))
            let count = tasks.count
            try await capacityEventually { await admission.waitingCount == count }
        }
        try await drain(admission, from: first, expecting: 3, log: log)
        #expect(await log.entries == [earlier, later, background])
        for task in tasks {
            try await task.value
        }
    }

    @Test func aBackgroundWaiterIsPassedOverAtMostTheBypassBound() async throws {
        let admission = AccountWorkAdmission(limit: 1, maximumBypasses: 2)
        let log = AdmissionLog()
        let first = UUID(); let background = UUID()
        let urgent = (0 ..< 3).map { _ in UUID() }
        try await admission.acquire(first)
        var tasks = [queue(admission, background, log: log)]
        try await capacityEventually { await admission.waitingCount == 1 }
        for id in urgent {
            tasks.append(queue(admission, id, urgency: WorkUrgency(interactive: true), log: log))
            let count = tasks.count
            try await capacityEventually { await admission.waitingCount == count }
        }
        try await drain(admission, from: first, expecting: 4, log: log)
        #expect(await log.entries == [urgent[0], urgent[1], background, urgent[2]])
        for task in tasks {
            try await task.value
        }
    }

    @Test func cancelingAQueuedInteractiveWaiterThrowsWithoutTakingASlot() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let log = AdmissionLog()
        let first = UUID(); let canceled = UUID(); let background = UUID()
        try await admission.acquire(first)
        let discarded = queue(admission, canceled, urgency: WorkUrgency(interactive: true), log: log)
        try await capacityEventually { await admission.waitingCount == 1 }
        let pending = queue(admission, background, log: log)
        try await capacityEventually { await admission.waitingCount == 2 }
        discarded.cancel()
        await #expect(throws: CancellationError.self) { try await discarded.value }
        #expect(await admission.waitingCount == 1)
        #expect(await admission.activeCount == 1)
        await admission.release(first)
        try await pending.value
        #expect(await log.entries == [background])
        await admission.release(background)
        #expect(await admission.activeCount == 0)
    }

    @Test func aNonCancellableInteractiveWaiterKeepsItsPlaceWhenCanceled() async throws {
        let admission = AccountWorkAdmission(limit: 1)
        let first = UUID(); let urgent = UUID()
        try await admission.acquire(first)
        let pending = Task {
            try await admission.acquire(urgent, cancellable: false, urgency: WorkUrgency(interactive: true))
        }
        try await capacityEventually { await admission.waitingCount == 1 }
        pending.cancel()
        #expect(await admission.waitingCount == 1)
        await admission.release(first)
        try await pending.value
        #expect(await admission.activeCount == 1)
        await admission.release(urgent)
    }

    @Test func raisingQueuedWorkLetsItUseTheReserve() async throws {
        let admission = AccountWorkAdmission(limit: 16, perOwnerLimit: 4, interactiveReserve: 1)
        let owner = UUID()
        let log = AdmissionLog()
        let background = (0 ..< 3).map { _ in UUID() }
        for id in background {
            try await admission.acquire(id, owner: owner)
        }
        let urgency = WorkUrgency()
        let read = UUID()
        let waiting = queue(admission, read, owner: owner, urgency: urgency, log: log)
        try await capacityEventually { await admission.waitingCount == 1 }
        urgency.raise()
        await admission.urgencyRaised()
        try await capacityEventually { await log.entries == [read] }
        #expect(await admission.activeCount == 4)
        for id in background + [read] {
            await admission.release(id)
        }
        try await waiting.value
    }

    @Test func raisedQueuedWorkStartsBeforeANewcomerTakesTheReserve() async throws {
        let admission = AccountWorkAdmission(limit: 16, perOwnerLimit: 4, interactiveReserve: 1)
        let owner = UUID()
        let log = AdmissionLog()
        let background = (0 ..< 3).map { _ in UUID() }
        for id in background {
            try await admission.acquire(id, owner: owner)
        }
        let urgency = WorkUrgency()
        let read = UUID(); let newcomer = UUID()
        let raised = queue(admission, read, owner: owner, urgency: urgency, log: log)
        try await capacityEventually { await admission.waitingCount == 1 }
        // Raised, but the admission has not been told yet.
        urgency.raise()
        let late = queue(admission, newcomer, owner: owner, urgency: WorkUrgency(interactive: true), log: log)
        try await capacityEventually { await log.entries.count == 1 }
        #expect(await log.entries == [read])
        #expect(await admission.waitingCount == 1)
        await admission.release(log.entries[0])
        try await capacityEventually { await log.entries.count == 2 }
        for id in await background + log.entries {
            await admission.release(id)
        }
        try await raised.value
        try await late.value
        #expect(await admission.activeCount == 0)
    }

    @Test func urgencyLastsWhileAnyoneIsWaiting() {
        let urgency = WorkUrgency()
        #expect(!urgency.isInteractive)
        urgency.raise(); urgency.raise()
        urgency.lower()
        #expect(urgency.isInteractive)
        urgency.lower()
        #expect(!urgency.isInteractive)
        urgency.lower()
        urgency.raise()
        #expect(urgency.isInteractive)
    }

    private func queue(
        _ admission: AccountWorkAdmission, _ id: UUID, owner: UUID? = nil, urgency: WorkUrgency? = nil,
        log: AdmissionLog
    ) -> Task<Void, any Error> {
        Task {
            try await admission.acquire(id, owner: owner, urgency: urgency)
            await log.record(id)
        }
    }

    /// Releases `first`, then each admitted waiter in turn once it starts.
    private func drain(
        _ admission: AccountWorkAdmission, from first: UUID, expecting count: Int, log: AdmissionLog
    ) async throws {
        await admission.release(first)
        for admitted in 1 ... count {
            try await capacityEventually { await log.entries.count == admitted }
            let entries = await log.entries
            await admission.release(entries[admitted - 1])
        }
    }
}

private actor AdmissionLog {
    private(set) var entries: [UUID] = []
    func record(_ id: UUID) {
        entries.append(id)
    }
}
