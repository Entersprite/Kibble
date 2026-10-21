import ChatKit
import Foundation

public extension LocalBridgeAudioCallService {
    func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        guard !hasCall, operation == nil, !isStopping,
              let person = people.values.first(where: { Self.recipient($0) == recipient })
        else { throw ChatError.unsupported(capability: "canMakeAudioCalls") }
        callScope = UUID()
        muteSequence = 0
        incomingHandle = nil
        let current = AudioCallSnapshot(
            id: callID, recipient: recipient, direction: .outgoing, phase: .connecting
        )
        snapshot = current
        continuation.yield(.snapshot(current))
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            let prepared = try await self.trial.prepare(person: person.id)
            try self.checkCall(callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
            try await self.trial.ring(preparedID: prepared.id)
            try self.checkCall(callID, scope: scope)
        }
    }

    func accept(callID: UUID) async throws {
        guard let current = snapshot, current.id == callID, current.phase == .incoming,
              let handle = incomingHandle, let incoming, operation == nil, !isStopping
        else { throw CancellationError() }
        publish(phase: .connecting, snapshot: current)
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            let prepared = try await incoming.accept(handle)
            try self.checkCall(callID, scope: scope)
            self.incomingHandle = nil
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
            // Only the provider's observed active-peer state confirms that
            // the incoming caller is still present after our join.
        }
    }

    func decline(callID: UUID) async throws {
        guard let current = snapshot, current.id == callID, current.phase == .incoming,
              let handle = incomingHandle, let incoming, operation == nil, !isStopping
        else { throw CancellationError() }
        // Hide the pending state while consuming the invitation once.
        publish(phase: .connecting, snapshot: current)
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            try await incoming.decline(handle)
            try self.checkCall(callID, scope: scope)
            self.incomingHandle = nil
            if let current = self.snapshot {
                self.publish(phase: .declined, snapshot: current, endReason: .localEnded)
            }
        }
    }

    func hangUp(callID: UUID) async throws {
        guard let current = snapshot, current.id == callID, !isStopping else { return }
        if current.phase == .incoming {
            try await decline(callID: callID); return
        }
        guard hasCall || operation != nil else { return }
        let endingScope = callScope
        callScope = UUID()
        let pending = operation
        pending?.cancel()
        media?.setMuted(true)
        if current.phase == .ringing {
            await trial.cancelNativeRing()
        } else {
            await trial.endNativeCall()
        }
        _ = await pending?.result
        let cleanup = await trial.cleanupOutcome(for: endingScope)
        guard snapshot?.id == callID, !isStopping else { return }
        if let handle = incomingHandle {
            await incoming?.dismiss(handle)
        }
        operation = nil
        media = nil
        incomingHandle = nil
        publish(phase: .ended, snapshot: current, failure: cleanup.message, endReason: .localEnded)
    }

    internal func runOperation(
        id: UUID, scope: UUID, perform: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let task = Task {
            try Task.checkCancellation()
            try await perform()
        }
        operation = task
        defer {
            if callScope == scope {
                operation = nil
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            guard snapshot?.id == id, callScope == scope, !isStopping else { throw CancellationError() }
            // Failed invitation/setup must release both local audio and the
            // registered device before another call is permitted.
            media?.setMuted(true)
            await trial.endNativeCall()
            let cleanup = await trial.cleanupOutcome(for: scope)
            media = nil
            guard snapshot?.id == id, callScope == scope, !isStopping else { throw CancellationError() }
            if let handle = incomingHandle {
                await incoming?.dismiss(handle)
            }
            incomingHandle = nil
            let message = [Self.failureMessage(error), cleanup.message].compactMap(\.self)
                .joined(separator: " ")
            if let current = snapshot {
                publish(phase: .failed, snapshot: current, failure: message)
            }
            throw ChatError.transport(message)
        }
    }

    internal func connect(_ ticket: UUID, id: UUID, scope: UUID) async throws {
        try checkCall(id, scope: scope)
        let engine = mediaFactory()
        engine.setMuted(false)
        media = engine
        try await trial.joinNative(preparedID: ticket, media: engine, scope: scope) { [weak self] state in
            await self?.receiveNative(state, id: id, scope: scope)
        }
        try checkCall(id, scope: scope)
        guard await trial.nativeOutgoingAudioReady(scope: scope) else {
            throw CallMediaError.outgoingAudioUnconfirmed
        }
    }
}
