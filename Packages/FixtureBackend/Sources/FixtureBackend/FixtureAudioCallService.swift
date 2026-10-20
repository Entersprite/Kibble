import ChatKit
import Foundation

/// Deterministic audio state without microphone, network, provider code or timers.
@MainActor
public final class FixtureAudioCallService: AudioCallQuiescing {
    public let events: AsyncStream<AudioCallEvent>
    public private(set) var currentCall: AudioCallSnapshot?
    public private(set) var recipients: [AudioCallRecipient]
    private let continuation: AsyncStream<AudioCallEvent>.Continuation
    private var listening = false
    private var sequence: UInt64 = 0

    public init(world: FixtureWorld = .acme) {
        recipients = world.conversations.compactMap { conversation in
            let other = conversation.members.filter { $0 != world.me }
            guard conversation.kind == .directMessage, other.count == 1,
                  conversation.members.contains(world.me),
                  let member = world.member(other[0]), member.kind == .human else { return nil }
            return AudioCallRecipient(
                conversationID: conversation.id, memberID: member.id,
                displayName: member.displayName ?? "Person"
            )
        }
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    public func startListening() async throws {
        listening = true
        continuation.yield(.recipientsChanged(recipients))
        continuation.yield(.listenerChanged(isListening: true))
    }

    public func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        self.recipients = recipients
        if listening {
            continuation.yield(.recipientsChanged(recipients))
        }
    }

    public func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        guard listening, recipients.contains(recipient), currentCall?.phase.isTerminal != false else {
            throw ChatError.unsupported(capability: "audioCall")
        }
        publish(AudioCallSnapshot(id: callID, recipient: recipient, direction: .outgoing, phase: .ringing))
        setPhase(.connected, callID: callID)
    }

    public func accept(callID: UUID) async throws {
        guard currentCall?.id == callID, currentCall?.phase == .incoming else {
            throw ChatError.unsupported(capability: "audioCall")
        }
        setPhase(.connected, callID: callID)
    }

    public func decline(callID: UUID) async throws {
        setPhase(.declined, callID: callID)
    }

    public func hangUp(callID: UUID) async throws {
        setPhase(.ended, callID: callID)
    }

    public func setMuted(_ muted: Bool, callID: UUID) async throws {
        guard var call = currentCall, call.id == callID, !call.phase.isTerminal else { return }
        call.isMuted = muted
        publish(call)
    }

    public func beginStopping() {
        listening = false
    }

    public func stop() async {
        listening = false
        currentCall = nil
        continuation.yield(.recipientsChanged([]))
    }

    public func pauseForRecovery(barrier: UUID) async throws {
        await stop()
        continuation.yield(.listenerBarrier(barrier))
    }

    /// A script/test can produce an incoming call explicitly. UUIDs use a counter.
    @discardableResult
    public func receiveIncoming(from recipient: AudioCallRecipient) -> UUID? {
        guard listening, recipients.contains(recipient),
              currentCall?.phase.isTerminal != false else { return nil }
        sequence += 1
        let bytes = (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        let id = UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]
        ))
        publish(AudioCallSnapshot(id: id, recipient: recipient, direction: .incoming, phase: .incoming))
        return id
    }

    public func remoteEnded(callID: UUID) {
        setPhase(.ended, callID: callID)
    }

    private func setPhase(_ phase: AudioCallPhase, callID: UUID) {
        guard var call = currentCall, call.id == callID else { return }
        call.phase = phase
        publish(call)
    }

    private func publish(_ call: AudioCallSnapshot) {
        currentCall = call
        continuation.yield(.snapshot(call))
    }
}
