import ChatKit
import Foundation

extension LocalBridgeAudioCallService: ConversationAudioCallService {
    public var canCallConversations: Bool {
        true
    }

    public func startConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await beginConversation(target, callID: callID, joining: false)
    }

    public func joinConversationCall(to target: ConversationCallTarget, callID: UUID) async throws {
        try await beginConversation(target, callID: callID, joining: true)
    }

    private func beginConversation(
        _ target: ConversationCallTarget,
        callID: UUID,
        joining: Bool
    ) async throws {
        guard !hasCall, operation == nil, !isStopping else {
            throw ChatError.unsupported(capability: "conversationCalls")
        }
        callScope = UUID()
        muteSequence = 0
        incomingHandle = nil
        snapshot = nil
        publishConversation(.init(id: callID, target: target, phase: .connecting))
        let scope = callScope
        try await runOperation(id: callID, scope: scope, canWaitForAdmission: true) {
            try await self.waitForCallContext(callID: callID, scope: scope)
            let prepared = try await self.trial.prepareConversation(
                in: Self.conversationID(target),
                joining: joining
            )
            try self.checkCall(callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
        }
    }

    private static func conversationID(_ target: ConversationCallTarget) throws -> Conversation.ID {
        guard let id = target.conversationID, target.meetingURL == nil else { throw CancellationError() }
        return id
    }

    func publishConversation(_ call: ConversationCallSnapshot) {
        conversationSnapshot = call
        continuation
            .yield(call.target.meetingURL == nil ? .conversationSnapshot(call) : .meetingSnapshot(call))
    }

    func hangUpConversation(callID: UUID) async throws {
        guard var current = conversationSnapshot, current.id == callID, !isStopping,
              !current.phase.isTerminal || operation != nil else { return }
        let scope = callScope
        callScope = UUID()
        admissionReceipt = nil
        cancelMeetingAgendaRead()
        let pending = operation
        pending?.cancel()
        media?.setMuted(true)
        await trial.endNativeCall()
        _ = await pending?.result
        let cleanup = await trial.cleanupOutcome(for: scope)
        guard conversationSnapshot?.id == callID, !isStopping else { return }
        operation = nil
        media = nil
        current.phase = .ended
        current.admission = nil
        current.endReason = .localEnded
        current.failureMessage = cleanup.message
        publishConversation(current)
    }

    func setConversationMuted(_ muted: Bool, callID: UUID) async throws {
        guard var current = conversationSnapshot, current.id == callID, current.phase == .connected,
              let media, !isStopping else { throw CancellationError() }
        guard muted || media.allowsMicrophone else { throw CallMediaError.captureRestricted }
        muteSequence += 1
        let sequence = muteSequence
        let scope = callScope
        media.setMuted(muted)
        current.isMuted = muted
        publishConversation(current)
        var confirmed = false
        do { confirmed = try await trial.setNativeMuted(muted, scope: scope, sequence: sequence) } catch {}
        try checkCall(callID, scope: scope)
        guard muteSequence == sequence, var latest = conversationSnapshot else { return }
        latest.failureMessage = confirmed ? nil : "Microphone changed locally; call status is unconfirmed."
        publishConversation(latest)
    }

    func receiveConversationNative(_ state: MeetNativeCallState, id: UUID, scope: UUID) {
        guard var current = conversationSnapshot, current.id == id, callScope == scope,
              !isStopping else { return }
        let previousAdmission = current.admission
        switch state {
        case .ready:
            guard current.admission != nil else { return }
            current.admission = nil
        case .ringing, .ending: return
        case let .awaitingAdmission(status):
            current.phase = .connecting
            current.failureMessage = nil
            current.admission = status
            publishConversation(current)
            updateWaitingRoomDetails(from: previousAdmission, call: current, scope: scope)
            admissionReceipt?.finish()
            admissionReceipt = nil
            return
        case .active:
            current.phase = .connected
            current.admission = nil
            current.failureMessage = nil
        case .reconnecting, .stateUnavailable:
            current.phase = .connecting
            current.failureMessage = "Call connection is interrupted."
        case let .ended(reason):
            finishConversation(&current, reason: reason, cleanup: MeetNativeCallCleanup())
        case let .endedUnconfirmed(reason, cleanup):
            finishConversation(&current, reason: reason, cleanup: cleanup)
        }
        publishConversation(current)
        updateWaitingRoomDetails(from: previousAdmission, call: current, scope: scope)
    }

    private func updateWaitingRoomDetails(
        from previous: CallAdmission?, call: ConversationCallSnapshot, scope: UUID
    ) {
        guard previous != call.admission else { return }
        if call.admission == .waitingRoom {
            if let url = call.target.meetingURL {
                readWaitingRoomAgenda(at: url, callID: call.id, scope: scope)
            }
        } else if previous == .waitingRoom {
            cancelWaitingRoomAgendaRead()
            continuation.yield(.interactionChanged(callID: call.id, state: nil))
        }
    }

    private func finishConversation(
        _ call: inout ConversationCallSnapshot, reason: MeetNativeCallEndReason,
        cleanup: MeetNativeCallCleanup
    ) {
        cancelMeetingAgendaRead()
        media = nil
        call.admission = nil
        switch reason {
        case .transportFailed, .joinFailed, .accountChanged:
            call.phase = .failed
            call.failureMessage = cleanup.message ?? "The call connection ended."
        default:
            call.phase = .ended
            call.failureMessage = cleanup.message
            call.endReason = switch reason {
            case .localEnded: .localEnded
            case .removedFromMeeting: .removedFromMeeting
            case .sentToWaitingRoom: .sentToWaitingRoom
            default: nil
            }
        }
    }
}
