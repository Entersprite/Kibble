import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func validateConversationSource(_ request: ControlConversationCall) throws {
        try checkActive()
        guard ["start", "join"].contains(request.action) else { throw ServiceFailure.unsupportedOperation }
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
    }

    func controlConversation(
        _ request: ControlConversationCall, target: ConversationCallTarget, session: ClientSessionID
    ) async throws -> ServiceCallState {
        try validateConversationSource(request)
        guard !controlling else { throw ServiceFailure.deviceBusy }
        controlling = true
        defer { controlling = false }
        guard state.supportsConversationCalls == true,
              let conversations = source as? any ConversationAudioCallService else {
            throw ServiceFailure.unsupportedOperation
        }
        guard state.currentPhase?.isTerminal != false, reserved == nil, !recoveryPaused else {
            throw ServiceFailure.deviceBusy
        }
        let id = request.callID
        guard !used.contains(id) else { throw ServiceFailure.operationConflict }
        guard used.count < 1024 else { throw ServiceFailure.overloaded }
        try await reserve(id, session: session)
        guard state.currentPhase?.isTerminal != false else {
            await releaseReservation()
            throw ServiceFailure.deviceBusy
        }
        used.insert(id)
        state.participants = nil
        state.call = nil
        state.conversationCall = .init(id: id, target: target, phase: .connecting)
        publish()
        do {
            if request.action == "join" {
                try await conversations.joinConversationCall(to: target, callID: id)
            } else {
                try await conversations.startConversationCall(to: target, callID: id)
            }
        } catch {
            // Even a source which fails before emitting its terminal event must
            // settle the reservation. Suppress/drain media before releasing it.
            try? await source.hangUp(callID: id)
            if state.conversationCall?.id == id, state.currentPhase?.isTerminal != true {
                state.conversationCall?.phase = .failed
                state.conversationCall?.failureMessage = "The call could not be connected."
                await releaseReservation()
                publish()
            }
            throw error
        }
        try checkActive()
        return state
    }
}
