import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchBlockedConversations(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canManageBlockedConversations else { throw ServiceFailure.unsupportedOperation }
        let value: JSONValue
        if request.operation == GetBlockedConversations.operation {
            _ = try request.decodePayload(GetBlockedConversations.self)
            let rows = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
                try await backend.blockedConversations()
            }
            value = try ServiceCodec.value(Self.validatedBlockedConversations(rows))
        } else {
            let payload = try request.decodePayload(UnblockConversation.self)
            guard Self.validBlockedConversationID(payload.conversation) else {
                throw ServiceFailure.invalidRequest
            }
            value = try await performOperation(payload.operationID, request: request, epoch: epoch) {
                let rows = try await backend.unblockConversation(payload.conversation)
                guard !rows.contains(where: { $0.id == payload.conversation }) else {
                    throw ServiceFailure.invalidResponse
                }
                return try Self.validatedBlockedConversations(rows)
            }
            try checkEpoch(epoch)
            worldVersion = UUID()
            reads.directoryCompletedAt = nil
            requestWorldRefresh()
        }
        try checkEpoch(epoch)
        return value
    }

    private static func validBlockedConversationID(_ id: Conversation.ID) -> Bool {
        !id.rawValue.isEmpty && id.rawValue.utf8.count <= 4096
    }

    private static func validatedBlockedConversations(
        _ rows: [BlockedConversation]
    ) throws -> [BlockedConversation] {
        guard rows.count <= 4096, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ validBlockedConversationID($0.id) && $0.name.utf8.count <= 4096 }) else {
            throw ServiceFailure.invalidResponse
        }
        return rows
    }
}
