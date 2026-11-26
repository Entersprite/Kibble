import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchScheduledMessages(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canScheduleMessages else { throw ServiceFailure.unsupportedOperation }
        let value: JSONValue
        switch request.operation {
        case GetScheduledMessages.operation:
            value = try await readScheduledMessages(request, backend: backend, epoch: epoch)
        case ScheduleMessage.operation:
            value = try await scheduleMessage(request, backend: backend, epoch: epoch)
        case EditScheduledMessage.operation:
            value = try await editScheduledMessage(request, backend: backend, epoch: epoch)
        case RescheduleMessage.operation:
            let payload = try request.decodePayload(RescheduleMessage.self)
            guard payload.address.isValid else { throw ServiceFailure.invalidRequest }
            value = try await performOperation(payload.operationID, request: request, epoch: epoch) {
                let message = try await backend.rescheduleMessage(payload.address, at: payload.deliveryTime)
                guard message.id == payload.address else { throw ServiceFailure.invalidResponse }
                return message
            }
        case CancelScheduledMessage.operation:
            value = try await cancelScheduledMessage(request, backend: backend, epoch: epoch)
        case SendScheduledMessageNow.operation:
            value = try await sendScheduledMessageNow(request, backend: backend, epoch: epoch)
        default:
            throw ServiceFailure.unsupportedOperation
        }
        try checkEpoch(epoch)
        return value
    }

    private func cancelScheduledMessage(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(CancelScheduledMessage.self)
        guard payload.address.isValid else { throw ServiceFailure.invalidRequest }
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.cancelScheduledMessage(payload.address)
            return ServiceUnit()
        }
    }

    private func sendScheduledMessageNow(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canSendScheduledMessagesNow else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(SendScheduledMessageNow.self)
        guard payload.address.isValid else { throw ServiceFailure.invalidRequest }
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.sendScheduledMessageNow(payload.address)
            return ServiceUnit()
        }
    }

    private func readScheduledMessages(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(GetScheduledMessages.self)
        guard Self.validScheduledCursor(payload.cursor) else { throw ServiceFailure.invalidRequest }
        let page = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            try await backend.scheduledMessages(after: payload.cursor)
        }
        guard page.messages.count <= 30, page.messages.allSatisfy(\.id.isValid),
              Set(page.messages.map(\.id)).count == page.messages.count,
              Self.validScheduledCursor(page.nextCursor),
              page.nextCursor == nil || page.nextCursor != payload.cursor else {
            throw ServiceFailure.invalidResponse
        }
        return try ServiceCodec.value(page)
    }

    private func scheduleMessage(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(ScheduleMessage.self)
        guard !payload.conversation.rawValue.isEmpty, payload.thread?.rawValue.isEmpty != true else {
            throw ServiceFailure.invalidRequest
        }
        let attachments = payload.attachments ?? []
        if !attachments.isEmpty {
            guard capabilities.canScheduleAttachments else { throw ServiceFailure.unsupportedOperation }
            guard Set(attachments.map(\.id)).count == attachments.count else {
                throw ServiceFailure.invalidRequest
            }
        }
        try payload.body.validateForScheduling(
            in: payload.conversation, capabilities: capabilities, hasAttachments: !attachments.isEmpty
        )
        let address = ComposerDraftAddress(conversation: payload.conversation, thread: payload.thread)
        if let draft = payload.draft {
            guard capabilities.canScheduleSavedDraft else { throw ServiceFailure.unsupportedOperation }
            guard draft.canRestore,
                  Self.validDraft(draft, in: address) else { throw ServiceFailure.invalidRequest }
        }
        return try await performOperation(payload.operationID, request: request, epoch: epoch, authorize: {
            try authorizeUploadedAttachments(attachments, for: address.conversation)
            try authorizeForwardSource(payload.body.content?.forwardSource, to: address.conversation)
        }, perform: {
            let message = if !attachments.isEmpty {
                try await backend.scheduleWithAttachments(
                    in: address, body: payload.body, attachments: attachments,
                    at: payload.deliveryTime, converting: payload.draft
                )
            } else if let draft = payload.draft {
                try await backend.scheduleSavedDraft(draft, body: payload.body, at: payload.deliveryTime)
            } else {
                try await backend.scheduleMessage(
                    in: payload.conversation, thread: payload.thread, body: payload.body,
                    at: payload.deliveryTime
                )
            }
            guard message.id.isValid, message.id.conversation == payload.conversation,
                  message.id.thread == payload.thread,
                  payload.draft.map({ message.id.queueID == $0.id.record }) ?? true else {
                throw ServiceFailure.invalidResponse
            }
            return message
        })
    }

    private func editScheduledMessage(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(EditScheduledMessage.self)
        guard payload.address.isValid else { throw ServiceFailure.invalidRequest }
        try payload.body.validateForScheduling(
            in: payload.address.conversation,
            capabilities: capabilities,
            editingCaption: true
        )
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            let message = try await backend.editScheduledMessage(payload.address, body: payload.body)
            guard message.id == payload.address else { throw ServiceFailure.invalidResponse }
            return message
        }
    }

    private static func validScheduledCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return true }
        return !cursor.isEmpty && cursor.utf8.count <= 4096
    }
}
