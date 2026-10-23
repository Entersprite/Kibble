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
        guard !hasCall, operation == nil, !isStopping, hasLoadedPeople else {
            throw ChatError.unsupported(capability: "conversationCalls")
        }
        callScope = UUID()
        muteSequence = 0
        incomingHandle = nil
        snapshot = nil
        publishConversation(.init(id: callID, target: target, phase: .connecting))
        let scope = callScope
        try await runOperation(id: callID, scope: scope) {
            let prepared = try await self.trial.prepareConversation(
                in: target.conversationID,
                joining: joining
            )
            try self.checkCall(callID, scope: scope)
            try await self.connect(prepared.id, id: callID, scope: scope)
            try self.checkCall(callID, scope: scope)
        }
    }

    func publishConversation(_ call: ConversationCallSnapshot) {
        conversationSnapshot = call
        continuation.yield(.conversationSnapshot(call))
    }

    func hangUpConversation(callID: UUID) async throws {
        guard var current = conversationSnapshot, current.id == callID, !isStopping,
              !current.phase.isTerminal || operation != nil else { return }
        let scope = callScope
        callScope = UUID()
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
        current.endReason = .localEnded
        current.failureMessage = cleanup.message
        publishConversation(current)
    }

    func setConversationMuted(_ muted: Bool, callID: UUID) async throws {
        guard var current = conversationSnapshot, current.id == callID, current.phase == .connected,
              let media, !isStopping else { throw CancellationError() }
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
        switch state {
        case .ready, .ringing, .ending: return
        case .active:
            current.phase = .connected
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
    }

    private func finishConversation(
        _ call: inout ConversationCallSnapshot, reason: MeetNativeCallEndReason,
        cleanup: MeetNativeCallCleanup
    ) {
        media = nil
        switch reason {
        case .transportFailed, .joinFailed, .accountChanged:
            call.phase = .failed
            call.failureMessage = cleanup.message ?? "The call connection ended."
        default:
            call.phase = .ended
            call.failureMessage = cleanup.message
            call.endReason = reason == .localEnded ? .localEnded : nil
        }
    }
}
