import ChatAPI
import ChatKit
import Foundation

actor ServiceCallRuntime {
    let source: any AudioCallService
    let reservations: CallDeviceReservations
    let cleanupAdmission: AccountWorkAdmission
    let device: CallDeviceReservations.Device
    let identity = UUID()
    private var sequence: UInt64 = 0
    var state: ServiceCallState
    var owner: ClientSessionID?
    var reserved: UUID?
    var used: Set<UUID> = []
    var controlling = false
    var stopped = false
    var recoveryPaused = false
    var recoveryBarrier: CallRecoveryBarrier?
    private var directoryRecipients: [AudioCallRecipient]?
    private var reader: Task<Void, Never>?
    var listener: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var waiters: [UUID: CallStateWaiter] = [:]
    var waitingReaderCount: Int {
        waiters.count
    }

    init(
        source: any AudioCallService, reservations: CallDeviceReservations,
        principal: ServicePrincipalID, device: ServiceDeviceID,
        cleanupAdmission: AccountWorkAdmission = AccountWorkAdmission(limit: 8)
    ) {
        self.cleanupAdmission = cleanupAdmission
        self.source = source; self.reservations = reservations
        self.device = .init(principal: principal, device: device)
        state = .init(version: identity.uuidString + ":0", isListenerStarting: true)
    }

    func start() async {
        guard reader == nil, !stopped else { return }
        let events = await source.events
        guard !stopped else { return }
        let joining = source as? any ExistingAudioCallService
        let canJoin = await joining?.canJoinExistingCalls == true
        guard !stopped else { return }
        if canJoin {
            state.supportsExistingJoin = true
            publish()
        }
        let conversations = source as? any ConversationAudioCallService
        let canCall = await conversations?.canCallConversations == true
        guard !stopped else { return }
        if canCall {
            state.supportsConversationCalls = true
            publish()
        }
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
        directoryRecipients = nil
        if !state.isListenerStarting {
            state.isListenerStarting = true
            publish()
        }
        listener = Task { [weak self, source] in
            do {
                try await source.startListening()
            } catch { await self?.listenerFailed() }
            await self?.listenerFinished()
        }
    }

    func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        guard !stopped, directoryRecipients != recipients else { return }
        directoryRecipients = recipients
        await source.updateRecipients(recipients)
    }

    private func listenerFinished() {
        listener = nil
    }

    private func listenerFailed() {
        guard !stopped else { return }
        state.isListening = false
        state.isListenerStarting = false
        state.lastEvent = .listenerChanged(isListening: false)
        publish()
    }

    func read(_ request: ReadCallState, control: Bool = false) async throws -> ServiceCallState {
        try checkActive()
        guard (0 ... 20000).contains(request.waitMilliseconds),
              request.after?.utf8.count ?? 0 <= 128 else { throw ServiceFailure.invalidRequest }
        guard request.after == state.version, request.waitMilliseconds > 0 else { return state }
        guard waiters.count < (control ? 9 : 8) else { throw ServiceFailure.overloaded }
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
        cancelRecoveryWait(throwing: ServiceFailure.accountDisabled)
        reader?.cancel(); listener?.cancel()
        let pending = waiters.values
        waiters = [:]
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: ServiceFailure.accountDisabled)
        }
        let task = Task {
            if let quiescing = source as? any AudioCallQuiescing {
                await quiescing.beginStopping()
                await cleanupAdmission.cleanup { [source] in await source.stop() }
            } else {
                await source.stop()
            }
            await reader?.value; await listener?.value
            await releaseReservation()
        }
        stopping = task
        await task.value
        reader = nil; listener = nil
    }

    private func receive(_ event: AudioCallEvent) async {
        guard !stopped else { return }
        if case let .listenerBarrier(token) = event {
            acknowledgeRecoveryBarrier(token)
            return
        }
        guard !recoveryPaused else { return }
        guard await applyCallEvent(event) else { return }
        guard !stopped else { return }
        state.lastEvent = event
        publish()
    }

    private func applyCallEvent(_ event: AudioCallEvent) async -> Bool {
        switch event {
        case let .recipientsChanged(recipients):
            guard recipients.count <= 4096 else { listenerFailed(); return false }
            state.recipients = recipients
        case let .listenerChanged(listening):
            state.isListening = listening
            state.isListenerStarting = false
        case let .snapshot(snapshot):
            return await receiveSnapshot(snapshot)
        case let .conversationSnapshot(snapshot):
            return await receiveConversationSnapshot(snapshot)
        case let .participantsChanged(id, participants):
            guard state.currentCallID == id, state.currentPhase?.isTerminal == false,
                  participants?.count ?? 0 <= 256,
                  Set(participants?.map(\.id) ?? []).count == (participants?.count ?? 0) else { return false }
            state.participants = participants
        case .unknown, .listenerBarrier: break
        }
        return true
    }

    private func receiveSnapshot(_ snapshot: AudioCallSnapshot) async -> Bool {
        if snapshot.phase == .incoming, used.count >= 1024, !used.contains(snapshot.id) {
            return false
        }
        if reserved == nil, used.contains(snapshot.id), !snapshot.phase.isTerminal {
            return false
        }
        // A retired call cannot replace a newer active call's state.
        if let reserved, snapshot.id != reserved {
            return false
        }
        if let current = state.currentCallID, current != snapshot.id {
            guard state.currentPhase?.isTerminal != false, snapshot.phase == .incoming,
                  !used.contains(snapshot.id) else { return false }
        }
        if snapshot.phase == .ended || snapshot.phase == .failed || snapshot.phase == .declined {
            if !used.contains(snapshot.id) {
                guard used.count < 1024 else { return false }
                used.insert(snapshot.id)
            }
            await releaseReservation()
        }
        guard !stopped else { return false }
        state.conversationCall = nil
        if state.call?.id != snapshot.id || snapshot.phase.isTerminal {
            state.participants = nil
        }
        state.call = snapshot
        return true
    }

    private func receiveConversationSnapshot(_ snapshot: ConversationCallSnapshot) async -> Bool {
        // Group calls are explicit outgoing controls; unsolicited group snapshots
        // cannot acquire a device or replace a DM invitation.
        guard state.conversationCall?.id == snapshot.id,
              reserved == snapshot.id || snapshot.phase.isTerminal else { return false }
        if [.ended, .failed, .declined].contains(snapshot.phase) {
            await releaseReservation()
        }
        guard !stopped else { return false }
        state.call = nil
        if snapshot.phase.isTerminal {
            state.participants = nil
        }
        state.conversationCall = snapshot
        return true
    }

    func releaseReservation() async {
        guard let id = reserved else { return }
        await reservations.release(device, owner: .init(runtime: identity, call: id))
        if reserved == id {
            reserved = nil; owner = nil
        }
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
