import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func readMessagePins(
        in conversation: Conversation.ID, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canReadMessagePins else { throw ServiceFailure.unsupportedOperation }
        let value = try await mediaQuery(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            let value = try await backend.pinnedMessages(in: conversation)
            try Self.validatePins(value, in: conversation)
            return value
        } remember: { catalog, value, date in
            try catalog.rememberQueryMembers(value.members, at: date)
            try catalog.rememberQueryMedia(value.messages, at: date)
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(value)
    }

    func mutateMessagePin(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(SetMessagePinned.self)
        guard capabilities.canReadMessagePins else { throw ServiceFailure.unsupportedOperation }
        guard payload.address.message != nil, payload.address.thread != nil
        else { throw ServiceFailure.invalidRequest }
        let current = try await withProviderWork(epoch: epoch) {
            try await backend.pinnedMessages(in: payload.address.conversation)
        }
        try Self.validatePins(current, in: payload.address.conversation)
        guard current.canModify else { throw ServiceFailure.notAuthorized }
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            let value = try await backend.setMessagePinned(payload.pinned, at: payload.address)
            try Self.validatePins(value, in: payload.address.conversation)
            return value
        }
    }

    private static func validatePins(_ value: PinnedMessages, in conversation: Conversation.ID) throws {
        guard value.messages.count <= 100, value.members.count <= 512,
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ $0.conversationID == conversation && !$0.isDeleted })
        else { throw ServiceFailure.invalidRequest }
    }
}
