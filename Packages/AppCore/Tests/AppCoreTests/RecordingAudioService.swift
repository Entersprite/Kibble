import ChatKit
import Foundation
@testable import AppCore

@MainActor
class RecordingAudioService: AudioCallService {
    let events: AsyncStream<AudioCallEvent>
    let continuation: AsyncStream<AudioCallEvent>.Continuation
    let recipient: AudioCallRecipient
    var operations: [String] = []
    var listenCount = 0
    var directoryUpdates: [[AudioCallRecipient]] = []
    var stopCount = 0
    var suspendAccept = false
    var suspendStop = false
    var failMute = false
    var failOutgoingWithSafeSnapshot = false
    var outgoingFailure: (any Error)?
    var failListen = false
    var suspendMute = false
    var muteNotice: String?
    var hangUpNotice: String?
    var suspendHangUp = false
    var hangUpFailure = false
    var hangUpContinuation: CheckedContinuation<Void, Never>?
    var latestSnapshot: AudioCallSnapshot?
    var muteContinuations: [CheckedContinuation<Void, Never>] = []
    var acceptContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?

    init(recipient: AudioCallRecipient) {
        self.recipient = recipient
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    func startListening() async throws {
        listenCount += 1
        if failListen {
            throw ChatError.transport("private listener error")
        }
        continuation.yield(.recipientsChanged([recipient]))
    }

    func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        directoryUpdates.append(recipients)
    }

    func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        operations.append("outgoing")
        if let outgoingFailure {
            throw outgoingFailure
        }
        if failOutgoingWithSafeSnapshot {
            emit(AudioCallSnapshot(
                id: callID, recipient: recipient, direction: .outgoing, phase: .failed,
                failureMessage: "Microphone access is required."
            ))
            throw ChatError.transport("private provider diagnostic")
        }
    }

    func accept(callID: UUID) async throws {
        operations.append("accept")
        if suspendAccept {
            await withCheckedContinuation { acceptContinuation = $0 }
        }
    }

    func decline(callID: UUID) async throws {
        operations.append("decline")
    }

    func hangUp(callID: UUID) async throws {
        operations.append("hangup")
        if suspendHangUp {
            await withCheckedContinuation { hangUpContinuation = $0 }
        }
        if hangUpFailure {
            throw ChatError.transport("unconfirmed cleanup")
        }
        if let hangUpNotice {
            emit(AudioCallSnapshot(
                id: callID, recipient: recipient, direction: .outgoing,
                phase: .ended, failureMessage: hangUpNotice
            ))
        }
    }

    func setMuted(_ muted: Bool, callID: UUID) async throws {
        operations.append(muted ? "mute" : "unmute")
        if failMute {
            throw ChatError.transport("private provider error")
        }
        if suspendMute {
            if var snapshot = latestSnapshot {
                snapshot.isMuted = muted
                snapshot.failureMessage = muteNotice
                emit(snapshot)
            }
            await withCheckedContinuation { muteContinuations.append($0) }
        }
    }

    func stop() async {
        stopCount += 1
        if suspendStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
    }

    func snapshot(phase: AudioCallPhase, direction: AudioCallDirection) -> AudioCallSnapshot {
        AudioCallSnapshot(id: UUID(), recipient: recipient, direction: direction, phase: phase)
    }

    func emit(_ snapshot: AudioCallSnapshot) {
        latestSnapshot = snapshot
        continuation.yield(.snapshot(snapshot))
    }

    /// The controller's view of a call to one person, sent back as the
    /// provider's snapshot of it.
    func emit(_ session: AudioCallSession) {
        guard let recipient = session.recipient else { return }
        emit(AudioCallSnapshot(
            id: session.id, recipient: recipient, direction: session.direction, phase: session.phase,
            isMuted: session.isMuted, failureMessage: session.failureMessage, endReason: session.endReason,
            remoteMuted: session.remoteMuted
        ))
    }
}
