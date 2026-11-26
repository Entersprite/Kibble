import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchMutations(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        context: ServiceSessionContext?,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case SendHint.operation:
            return try await dispatchHint(request, backend: backend, context: context, epoch: epoch)
        case OpenDirectConversation.operation:
            let payload = try request.decodePayload(OpenDirectConversation.self)
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.openDirectConversation(with: payload.memberID)
            }
        case CreateConversation.operation:
            let payload = try request.decodePayload(CreateConversation.self)
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.createConversation(payload.draft)
            }
        case MutateConversation.operation:
            return try await dispatchConversationMutation(request, backend: backend, epoch: epoch)
        case InvokeCardAction.operation:
            let payload = try request.decodePayload(InvokeCardAction.self)
            guard capabilities.canInvokeCardActions else { throw ServiceFailure.unsupportedOperation }
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.invokeCardAction(payload.action)
            }
        case SendCommand.operation:
            return try await dispatchSend(request, backend: backend, epoch: epoch)
        default: return try await dispatchAppOpening(request, backend: backend, epoch: epoch)
        }
    }

    private func dispatchSend(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(SendCommand.self)
        guard !SendHint.accepts(payload.command) else { throw ServiceFailure.invalidRequest }
        if let draft = payload.draft {
            guard capabilities.canSendSavedDraft else { throw ServiceFailure.unsupportedOperation }
            guard draft.canConsume(
                      with: payload.command,
                      allowingAttachments: capabilities.canSendSavedDraftWithAttachments
                  ),
                  Self.validDraft(draft, in: nil) else {
                throw ServiceFailure.invalidRequest
            }
        }
        _ = try await performOperation(
            payload.operationID, request: request, epoch: epoch,
            authorize: {
                try authorizeForward(payload.command)
                try authorizePrivacy(payload.command)
                try authorizeUploadedAttachments(payload.command)
            }, perform: {
                if let draft = payload.draft {
                    let consumed = try await backend.send(payload.command, consuming: draft)
                    return SendCommandReceipt(draftConsumed: consumed)
                }
                try await backend.send(payload.command)
                return SendCommandReceipt()
            }
        )
        try checkEpoch(epoch)
        guard let operation = try storage.operation(payload.operationID)
        else { throw ServiceFailure.operationUnknown }
        return try ServiceCodec.value(operation)
    }

    private func dispatchAppOpening(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard request.operation == OpenConversationApp.operation,
              capabilities.canManageConversationApps else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(OpenConversationApp.self)
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.openAppConversation(payload.appID, from: payload.conversationID)
        }
    }

    private func dispatchConversationMutation(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(MutateConversation.self)
        try authorizeManagementMutation(payload.mutation)
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.mutateConversation(
                payload.mutation,
                in: payload.conversationID,
                operationID: payload.operationID.rawValue,
                expectedRevision: payload.expectedRevision
            )
        }
    }

    private func authorizeManagementMutation(_ mutation: ConversationMutation) throws {
        switch mutation {
        case .setPersonBlocked:
            guard capabilities.canBlockConversations else { throw ServiceFailure.unsupportedOperation }
        case .generateEmail, .setEmailDelivery, .deleteEmail:
            guard capabilities.canManageConversationEmail
            else { throw ServiceFailure.unsupportedOperation }
        case .addApp, .removeApp:
            guard capabilities.canManageConversationApps
            else { throw ServiceFailure.unsupportedOperation }
        case .saveWebhook, .deleteWebhook:
            guard capabilities.canManageConversationWebhooks
            else { throw ServiceFailure.unsupportedOperation }
        default: break
        }
    }
}
