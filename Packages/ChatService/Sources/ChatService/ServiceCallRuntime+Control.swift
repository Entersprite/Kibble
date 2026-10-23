import ChatAPI
import ChatKit
import Foundation

extension ServiceCallRuntime {
    func control(_ request: ControlCall, session: ClientSessionID) async throws -> ServiceCallState {
        try checkActive()
        try validateSource(request)
        guard request.recipient == nil || ["start", "join"].contains(request.action),
              request.muted == nil || request.action == "mute" else { throw ServiceFailure.invalidRequest }
        switch request.action {
        case "start", "join", "accept", "decline", "restart", "pause":
            guard !controlling else { throw ServiceFailure.deviceBusy }
            controlling = true
            defer { controlling = false }
            try await begin(request, session: session)
        case "hangUp", "mute":
            guard let id = request.callID, id == reserved, owner == session else {
                throw ServiceFailure.notAuthorized
            }
            if request.action == "hangUp" {
                try await source.hangUp(callID: id)
                try await waitForTerminal(id)
            } else {
                guard let muted = request.muted else { throw ServiceFailure.invalidRequest }
                try await source.setMuted(muted, callID: id)
            }
        default: throw ServiceFailure.unsupportedOperation
        }
        try checkActive()
        return state
    }

    func validateSource(_ request: ControlCall) throws {
        guard ["start", "join", "accept", "decline", "restart", "pause", "hangUp", "mute"]
            .contains(request.action)
        else {
            throw ServiceFailure.unsupportedOperation
        }
        guard request.sourceID == identity else { throw ServiceFailure.staleCallSource }
    }

    private func begin(_ request: ControlCall, session: ClientSessionID) async throws {
        if request.action == "pause" {
            try await pauseListener(request)
            return
        }
        if request.action == "restart" {
            try await restart(request)
            return
        }
        guard let id = request.callID else { throw ServiceFailure.invalidRequest }
        switch request.action {
        case "start", "join":
            try await startOutgoing(request, id: id, session: session)
        case "accept": try await acceptIncoming(id: id, session: session)
        case "decline":
            guard reserved == nil, state.call?.id == id, state.call?.phase == .incoming else {
                throw ServiceFailure.invalidRequest
            }
            guard !used.contains(id), used.count < 1024 else { throw ServiceFailure.overloaded }
            used.insert(id)
            try await source.decline(callID: id)
            try await waitForTerminal(id)
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    private func acceptIncoming(id: UUID, session: ClientSessionID) async throws {
        guard state.call?.id == id, state.call?.phase == .incoming else {
            throw ServiceFailure.invalidRequest
        }
        guard used.count < 1024, !used.contains(id) else { throw ServiceFailure.overloaded }
        try await reserve(id, session: session)
        guard state.call?.id == id, state.call?.phase == .incoming else {
            await releaseReservation()
            throw ServiceFailure.invalidRequest
        }
        used.insert(id)
        try await source.accept(callID: id)
    }

    private func restart(_ request: ControlCall) async throws {
        guard request.callID == nil, reserved == nil, state.currentPhase?.isTerminal != false else {
            throw ServiceFailure.deviceBusy
        }
        if !recoveryPaused {
            try await pauseListener(request)
        }
        try checkActive()
        guard recoveryBarrier?.arrived != false else { throw ServiceFailure.accountCleanupPending }
        recoveryBarrier = nil
        recoveryPaused = false
        startListener()
    }

    private func startOutgoing(_ request: ControlCall, id: UUID, session: ClientSessionID) async throws {
        if request.action == "join",
           state.supportsExistingJoin != true || !(source is any ExistingAudioCallService) {
            throw ServiceFailure.unsupportedOperation
        }
        guard state.currentPhase?.isTerminal != false, reserved == nil,
              !recoveryPaused,
              let hint = request.recipient,
              let recipient = state.recipients.first(where: {
                  $0.conversationID == hint.conversationID && $0.memberID == hint.memberID
              }) else { throw ServiceFailure.invalidRequest }
        guard !used.contains(id) else { throw ServiceFailure.operationConflict }
        guard used.count < 1024 else { throw ServiceFailure.overloaded }
        try await reserve(id, session: session)
        guard state.currentPhase?.isTerminal != false else {
            await releaseReservation()
            throw ServiceFailure.deviceBusy
        }
        used.insert(id)
        state.participants = nil
        state.conversationCall = nil
        state.call = .init(id: id, recipient: recipient, direction: .outgoing, phase: .connecting)
        publish()
        if request.action == "join" {
            guard let joining = source as? any ExistingAudioCallService else {
                throw ServiceFailure.unsupportedOperation
            }
            try await joining.joinExisting(to: recipient, callID: id)
        } else {
            try await source.startOutgoing(to: recipient, callID: id)
        }
    }

    func reserve(_ id: UUID, session: ClientSessionID) async throws {
        try await reservations.acquire(device, owner: .init(runtime: identity, call: id))
        do {
            try checkActive()
        } catch {
            await reservations.release(device, owner: .init(runtime: identity, call: id))
            throw error
        }
        reserved = id; owner = session
    }
}
