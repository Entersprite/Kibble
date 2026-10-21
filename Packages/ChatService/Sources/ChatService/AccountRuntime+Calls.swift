import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func invalidateCallFacts(for event: ChatEvent) {
        switch event {
        case let .conversationsChanged(conversations): invalidateCallWorld(conversations)
        case let .conversationClassified(row): invalidateCallMembership(row.id)
        case let .conversationUpdated(conversation):
            let previous = try? storage.conversation(conversation.id)
            if previous?.kind != conversation.kind ||
                (!conversation.members.isEmpty && Set(previous?.members ?? []) != Set(conversation.members)) {
                invalidateCallMembership(conversation.id)
            }
        case let .membersChanged(id, members):
            if Set((try? storage.conversation(id))?.members ?? []) != Set(members.map(\.id)) {
                invalidateCallMembership(id)
            }
        case let .conversationRemoved(id, _): invalidateCallMembership(id)
        case let .gap(scope: .conversation(id), reason: _): invalidateCallMembership(id)
        case .gap(scope: .everything, reason: _):
            callWorldVersion = UUID(); callFactsVersions = [:]
        default: break
        }
    }

    private func invalidateCallWorld(_ conversations: [Conversation]) {
        let previous = membershipFacts((try? storage.conversations()) ?? [])
        let current = membershipFacts(conversations, preserving: previous)
        for id in Set(previous.keys).union(current.keys) where previous[id] != current[id] {
            invalidateCallMembership(id)
        }
    }

    private func invalidateCallMembership(_ id: Conversation.ID) {
        if callFactsVersions[id] == nil, callFactsVersions.count >= 4096 {
            callWorldVersion = UUID(); callFactsVersions = [:]
        }
        callFactsVersions[id] = UUID()
    }

    private func membershipFacts(
        _ conversations: [Conversation], preserving previous: [Conversation.ID: Conversation] = [:]
    ) -> [Conversation.ID: Conversation] {
        Dictionary(uniqueKeysWithValues: conversations.map { row in
            let members = row.members.isEmpty ? previous[row.id]?.members ?? [] : row.members
            return (row.id, Conversation(
                id: row.id,
                kind: row.kind,
                members: members.sorted { $0.rawValue < $1.rawValue }
            ))
        })
    }

    func installCalls(_ sources: [ServiceDeviceID: any AudioCallService]) async {
        guard !stopped, !quarantinedForSubscription else {
            for source in sources.values {
                await source.stop()
            }
            return
        }
        guard sources.count <= 8 else {
            for source in sources.values {
                await source.stop()
            }
            await quarantine(.storage)
            return
        }
        for (device, source) in sources {
            let runtime = ServiceCallRuntime(
                source: source, reservations: callReservations, principal: record.principalID, device: device,
                cleanupAdmission: callCleanupAdmission
            )
            calls[device] = runtime
            await runtime.start()
            guard !stopped, !quarantinedForSubscription else {
                for source in sources.values {
                    await source.stop()
                }
                return
            }
        }
    }

    func stopCalls() -> [Task<Void, Never>] {
        if callStops.isEmpty {
            callStops = calls.values.map { runtime in Task { await runtime.stop() } }
        }
        return callStops
    }

    func dispatchCalls(
        _ request: ServiceRequest, context: ServiceSessionContext, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        try checkEpoch(epoch)
        guard let calls = calls[context.deviceID] else { throw ServiceFailure.unsupportedOperation }
        let result: ServiceCallState
        switch request.operation {
        case ReadCallState.operation:
            result = try await calls.read(request.decodePayload(ReadCallState.self))
        case ControlCall.operation:
            let control = try request.decodePayload(ControlCall.self)
            try await calls.validateSource(control)
            if control.action == "start" {
                try await validateCallRecipient(control.recipient, backend: backend, epoch: epoch)
            }
            result = try await calls.control(control, session: context.sessionID)
        default: throw ServiceFailure.unsupportedOperation
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(result)
    }

    private func validateCallRecipient(
        _ recipient: AudioCallRecipient?, backend: any ChatBackend, epoch: UUID
    ) async throws {
        guard let recipient, let conversation = try storage.conversation(recipient.conversationID),
              conversation.kind == .directMessage, recipient.memberID != record.selfID else {
            throw ServiceFailure.invalidRequest
        }
        let version = callFactsVersions[conversation.id]
        let world = callWorldVersion
        let membership = try await withProviderWork(epoch: epoch) {
            try await backend.membership(of: recipient.memberID, in: conversation.id)
        }
        try checkEpoch(epoch)
        guard version == callFactsVersions[conversation.id],
              world == callWorldVersion else { throw ServiceFailure.overloaded }
        guard membership == .member else { throw ServiceFailure.notAuthorized }
    }
}
