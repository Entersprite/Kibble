import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func invalidateCallFacts(for event: ChatEvent) {
        let changed: Bool
        switch event {
        case let .conversationsChanged(conversations):
            let previous = (try? storage.conversations()) ?? []
            changed = membershipFacts(previous) != membershipFacts(conversations)
        case let .conversationUpdated(conversation):
            let previous = try? storage.conversation(conversation.id)
            changed = previous?.kind != conversation
                .kind || Set(previous?.members ?? []) != Set(conversation.members)
        case let .membersChanged(id, members):
            let previous = try? storage.conversation(id)
            changed = Set(previous?.members ?? []) != Set(members.map(\.id))
        case .conversationRemoved, .gap: changed = true
        default: changed = false
        }
        if changed {
            callFactsVersion = UUID()
        }
    }

    private func membershipFacts(_ conversations: [Conversation]) -> [Conversation.ID: Conversation] {
        Dictionary(uniqueKeysWithValues: conversations.map {
            (
                $0.id,
                Conversation(
                    id: $0.id,
                    kind: $0.kind,
                    members: $0.members.sorted { $0.rawValue < $1.rawValue }
                )
            )
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
                cleanupAdmission: providerStops
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
        let version = callFactsVersion
        let membership = try await backend.membership(of: recipient.memberID, in: conversation.id)
        try checkEpoch(epoch)
        guard version == callFactsVersion else { throw ServiceFailure.overloaded }
        guard membership == .member else { throw ServiceFailure.notAuthorized }
    }
}
