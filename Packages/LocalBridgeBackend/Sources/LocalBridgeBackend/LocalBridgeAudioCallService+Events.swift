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
            conversationSnapshot = nil
            snapshot = next
            continuation.yield(.snapshot(next))
        case .cleared, .remoteEnded:
            guard let current = snapshot, current.phase == .incoming else { return }
            incomingHandle = nil
            let reason: AudioCallEndReason? = if case .remoteEnded = event {
                .remoteEnded
            } else {
                nil
            }
            publish(phase: .ended, snapshot: current, endReason: reason)
        }
    }

    func receiveNative(_ state: MeetNativeCallState, id: UUID, scope: UUID) {
        if conversationSnapshot?.id == id {
            receiveConversationNative(state, id: id, scope: scope)
            return
        }
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
            receiveEnd(reason, cleanup: MeetNativeCallCleanup(), current: current)
        case let .endedUnconfirmed(reason, cleanup):
            receiveEnd(reason, cleanup: cleanup, current: current)
        }
    }

    func receiveParticipants(_ participants: [CallParticipantDevice]?, id: UUID, scope: UUID) {
        guard currentCallID == id, callScope == scope, !isStopping else { return }
        continuation.yield(.participantsChanged(callID: id, participants: participants))
    }

    /// The other person's microphone, as the native session last read it.
    func receiveRemoteMuted(_ muted: Bool?, id: UUID, scope: UUID) {
        guard var current = snapshot, current.id == id, callScope == scope, !isStopping,
              !current.phase.isTerminal, current.remoteMuted != muted else { return }
        current.remoteMuted = muted
        snapshot = current
        continuation.yield(.snapshot(current))
    }

    private func receiveEnd(
        _ reason: MeetNativeCallEndReason, cleanup: MeetNativeCallCleanup, current: AudioCallSnapshot
    ) {
        media = nil
        incomingHandle = nil
        switch reason {
        case .transportFailed, .joinFailed, .accountChanged:
            publish(
                phase: .failed,
                snapshot: current,
                failure: cleanup.message ?? "The call connection ended."
            )
        default:
            let endReason: AudioCallEndReason? = switch reason {
            case .localEnded, .ringCancelled: .localEnded
            case .remoteEnded, .invitationEnded: .remoteEnded
            case .declined: .declined
            default: nil
            }
            publish(phase: .ended, snapshot: current, failure: cleanup.message, endReason: endReason)
        }
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        if conversationSnapshot?.id == callID {
            try await setConversationMuted(muted, callID: callID)
            return
        }
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
            phase: current.phase, isMuted: muted, remoteMuted: current.remoteMuted
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
