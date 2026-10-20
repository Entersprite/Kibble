import ChatAPI
import ChatKit
import Foundation

actor ServiceCallRuntime {
    let source: any AudioCallService
    let reservations: CallDeviceReservations
    let device: CallDeviceReservations.Device
    let identity = UUID()
    private var sequence: UInt64 = 0
    var state: ServiceCallState
    var owner: ClientSessionID?
    var reserved: UUID?
    var used: Set<UUID> = []
    var controlling = false
    var stopped = false
    private var reader: Task<Void, Never>?
    var listener: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var waiters: [UUID: CallStateWaiter] = [:]
    var waitingReaderCount: Int {
        waiters.count
    }

    init(
        source: any AudioCallService, reservations: CallDeviceReservations,
        principal: ServicePrincipalID, device: ServiceDeviceID
    ) {
        self.source = source; self.reservations = reservations
        self.device = .init(principal: principal, device: device)
        state = .init(version: identity.uuidString + ":0")
    }

    func start() async {
        guard reader == nil, !stopped else { return }
        let events = await source.events
        guard !stopped else { return }
        reader = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        startListener()
    }

    func startListener() {
        guard listener == nil, !stopped else { return }
        listener = Task { [weak self, source] in
            do {
                try await source.startListening()
            } catch { await self?.listenerFailed() }
            await self?.listenerFinished()
        }
    }

    private func listenerFinished() {
        listener = nil
    }

    private func listenerFailed() {
        guard !stopped else { return }
        state.isListening = false
        state.lastEvent = .listenerChanged(isListening: false)
        publish()
    }

    func read(_ request: ReadCallState) async throws -> ServiceCallState {
        try checkActive()
        guard (0 ... 20000).contains(request.waitMilliseconds),
              request.after?.utf8.count ?? 0 <= 128 else { throw ServiceFailure.invalidRequest }
        guard request.after == state.version, request.waitMilliseconds > 0 else { return state }
        guard waiters.count < 8 else { throw ServiceFailure.overloaded }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError()); return
                }
                let timeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(request.waitMilliseconds))
                    } catch { return }
                    await self?.finishWait(id)
                }
                waiters[id] = CallStateWaiter(continuation: continuation, timeout: timeout)
            }
        } onCancel: { Task { await self.cancelWait(id) } }
    }

    func stop() async {
        if let stopping {
            await stopping.value; return
        }
        stopped = true
        reader?.cancel(); listener?.cancel()
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: ServiceFailure.accountDisabled)
        }
        let task = Task {
            await source.stop()
            await reader?.value; await listener?.value
            await releaseReservation()
        }
        stopping = task
        await task.value
        reader = nil; listener = nil
    }

    private func receive(_ event: AudioCallEvent) async {
        guard !stopped else { return }
        switch event {
        case let .recipientsChanged(recipients):
            guard recipients.count <= 4096 else { listenerFailed(); return }
            state.recipients = recipients
        case let .listenerChanged(listening): state.isListening = listening
        case let .snapshot(snapshot):
            guard await receiveSnapshot(snapshot) else { return }
        case .unknown: break
        }
        guard !stopped else { return }
        state.lastEvent = event
        publish()
    }

    private func receiveSnapshot(_ snapshot: AudioCallSnapshot) async -> Bool {
        if reserved == nil, used.contains(snapshot.id), !snapshot.phase.isTerminal {
            return false
        }
        // A retired call cannot replace a newer active call's state.
        if let reserved, snapshot.id != reserved {
            return false
        }
        if let current = state.call, current.id != snapshot.id {
            guard current.phase.isTerminal, snapshot.phase == .incoming,
                  !used.contains(snapshot.id) else { return false }
        }
        state.call = snapshot
        if snapshot.phase == .ended || snapshot.phase == .failed || snapshot.phase == .declined {
            await releaseReservation()
        }
        return true
    }

    func releaseReservation() async {
        guard let id = reserved else { return }
        reserved = nil; owner = nil
        await reservations.release(device, owner: .init(runtime: identity, call: id))
    }

    func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw ServiceFailure.accountDisabled }
    }

    func publish() {
        guard sequence < UInt64.max else { return }
        sequence += 1
        state.version = identity.uuidString + ":" + String(sequence)
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.timeout.cancel(); waiter.continuation.resume(returning: state)
        }
    }

    private func finishWait(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: state)
    }

    private func cancelWait(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel(); waiter.continuation.resume(throwing: CancellationError())
    }
}

private struct CallStateWaiter {
    let continuation: CheckedContinuation<ServiceCallState, any Error>
    let timeout: Task<Void, Never>
}
