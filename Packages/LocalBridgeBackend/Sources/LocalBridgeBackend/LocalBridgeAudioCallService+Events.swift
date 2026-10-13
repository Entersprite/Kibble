import ChatKit
import Foundation

extension LocalBridgeAudioCallService {
    func receiveIncoming(_ event: MeetIncomingDMCalls.Event, scope: UUID) async {
        guard sessionScope == scope, !isStopping else { return }
        switch event {
        case .status: break
        case .listening: continuation.yield(.listenerChanged(isListening: true))
        case .listeningFailed: continuation.yield(.listenerChanged(isListening: false))
        case let .ring(offered):
            guard !hasCall, operation == nil, let person = people[offered.person] else {
                await incoming?.dismiss(offered.id)
                return
            }
            callScope = UUID()
            incomingHandle = offered.id
            muteSequence = 0
            let next = AudioCallSnapshot(
                id: UUID(), recipient: Self.recipient(person), direction: .incoming, phase: .incoming
            )
            snapshot = next
            continuation.yield(.snapshot(next))
        case .cleared:
            guard let current = snapshot, current.phase == .incoming else { return }
            incomingHandle = nil
            publish(phase: .ended, snapshot: current)
        }
    }

    func receiveNative(_ state: MeetNativeCallState, id: UUID, scope: UUID) {
        guard let current = snapshot, current.id == id, callScope == scope, !isStopping else { return }
        switch state {
        case .ready: break
        case .ringing: publish(phase: .ringing, snapshot: current)
        case .active: publish(phase: .connected, snapshot: current)
        case .reconnecting:
            publish(phase: .connecting, snapshot: current, failure: "Audio connection is interrupted.")
        case .stateUnavailable:
            publish(phase: .connecting, snapshot: current, failure: "Call status is unavailable.")
        case .ending: break
        case let .ended(reason):
            media = nil
            incomingHandle = nil
            switch reason {
            case .transportFailed, .joinFailed, .accountChanged:
                publish(phase: .failed, snapshot: current, failure: "The call connection ended.")
            default: publish(phase: .ended, snapshot: current)
            }
        }
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        guard let current = snapshot, current.id == callID,
              current.phase == .connected || current.phase == .ringing,
              let media, !isStopping else { throw CancellationError() }
        muteSequence += 1
        let sequence = muteSequence
        let scope = callScope
        // Local suppression is immediate even if the provider announcement
        // fails. Ordered sequences prevent a late mute changing a newer call.
        media.setMuted(muted)
        let next = AudioCallSnapshot(
            id: current.id, recipient: current.recipient, direction: current.direction,
            phase: current.phase, isMuted: muted
        )
        snapshot = next
        continuation.yield(.snapshot(next))
        var confirmed = false
        do { confirmed = try await trial.setNativeMuted(muted, scope: scope, sequence: sequence) } catch {}
        try checkCall(callID, scope: scope)
        guard sequence == muteSequence, let current = snapshot else { return }
        publish(
            phase: current.phase, snapshot: current,
            failure: confirmed ? nil : "Microphone changed locally; call status is unconfirmed."
        )
    }
}
