import ChatAPI
import ChatKit
import Foundation

public extension ServiceBackend {
    func scheduledMessages(after cursor: String?) async throws -> ScheduledMessagesPage {
        try await call(GetScheduledMessages(cursor: cursor))
    }

    func scheduleMessage(
        in conversation: Conversation.ID, thread: MessageThread.ID?, body: ComposedMessage,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try await call(ScheduleMessage(
            conversation: conversation, thread: thread, body: body, deliveryTime: deliveryTime,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func scheduleSavedDraft(
        _ draft: SyncedDraft, body: ComposedMessage, at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        guard capabilities.canScheduleSavedDraft else {
            throw ChatError.unsupported(capability: "scheduleSavedDraft")
        }
        let address = draft.id.address
        return try await call(ScheduleMessage(
            conversation: address.conversation, thread: address.thread, body: body,
            deliveryTime: deliveryTime, operationID: ServiceOperationID(ClientOperationID.make()),
            draft: draft
        ))
    }

    func scheduleWithAttachments(
        in address: ComposerDraftAddress, body: ComposedMessage, attachments: [Attachment],
        at deliveryTime: Date, converting draft: SyncedDraft?
    ) async throws -> ScheduledMessage {
        guard capabilities.canScheduleAttachments else {
            throw ChatError.unsupported(capability: "scheduleAttachments")
        }
        return try await call(ScheduleMessage(
            conversation: address.conversation, thread: address.thread, body: body,
            deliveryTime: deliveryTime,
            operationID: ServiceOperationID(ClientOperationID.make()), draft: draft, attachments: attachments
        ))
    }

    func editScheduledMessage(
        _ address: ScheduledMessageAddress,
        body: ComposedMessage
    ) async throws -> ScheduledMessage {
        try await call(EditScheduledMessage(
            address: address, body: body, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func rescheduleMessage(
        _ address: ScheduledMessageAddress,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try await call(RescheduleMessage(
            address: address, deliveryTime: deliveryTime,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func cancelScheduledMessage(_ address: ScheduledMessageAddress) async throws {
        _ = try await call(CancelScheduledMessage(
            address: address, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }

    func sendScheduledMessageNow(_ address: ScheduledMessageAddress) async throws {
        _ = try await call(SendScheduledMessageNow(
            address: address, operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
