import ChatAPI
import ChatKit
import Foundation

struct CallRecoveryBarrier {
    let token: UUID
    var arrived = false
    var continuation: CheckedContinuation<Void, any Error>?
}

extension ServiceCallRuntime {
    func pauseListener(_ request: ControlCall) async throws {
        guard request.callID == nil, reserved == nil, state.currentPhase?.isTerminal != false else {
            throw ServiceFailure.deviceBusy
        }
        if recoveryPaused, recoveryBarrier == nil {
            return
        }
        guard let quiescing = source as? any AudioCallQuiescing else {
            throw ServiceFailure.unsupportedOperation
        }
        let token = UUID()
        recoveryPaused = true
        recoveryBarrier = CallRecoveryBarrier(token: token)
        listener?.cancel()
        try await quiescing.pauseForRecovery(barrier: token)
        await listener?.value
        listener = nil
        try checkActive()
        try await waitForRecoveryBarrier(token)
        try checkActive()
        recoveryBarrier = nil
        state.isListening = false
        state.isListenerStarting = false
        state.recipients = []
        state.lastEvent = .listenerChanged(isListening: false)
        publish()
    }

    func acknowledgeRecoveryBarrier(_ token: UUID) {
        guard recoveryBarrier?.token == token else { return }
        recoveryBarrier?.arrived = true
        let continuation = recoveryBarrier?.continuation
        recoveryBarrier?.continuation = nil
        continuation?.resume()
    }

    func cancelRecoveryWait(throwing error: any Error) {
        let continuation = recoveryBarrier?.continuation
        recoveryBarrier?.continuation = nil
        continuation?.resume(throwing: error)
    }

    private func waitForRecoveryBarrier(_ token: UUID) async throws {
        guard recoveryBarrier?.token == token else { throw ServiceFailure.accountCleanupPending }
        if recoveryBarrier?.arrived == true {
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                Void,
                any Error
            >) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                recoveryBarrier?.continuation = continuation
            }
        } onCancel: { Task { await self.cancelRecoveryWait(throwing: CancellationError()) } }
    }
}
