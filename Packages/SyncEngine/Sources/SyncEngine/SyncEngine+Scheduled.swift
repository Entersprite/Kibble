import ChatKit
import Foundation

enum ScheduleChange: Sendable {
    case create(
        MessageAddress,
        ComposedMessage,
        Date,
        converting: SyncedDraft?,
        attachments: [Attachment] = []
    )
    case edit(ScheduledMessageAddress, ComposedMessage)
    case move(ScheduledMessageAddress, Date)
    case sendNow(ScheduledMessageAddress)
    case cancel(ScheduledMessageAddress)
}

extension SyncEngine {
    func scheduledPage(after cursor: String?) async throws -> ScheduledMessagesPage {
        try await inScheduledSession { try await $0.scheduledMessages(after: cursor) }
    }

    func changeSchedule(_ change: ScheduleChange) async throws -> ScheduledMessage? {
        try await inScheduledSession { backend in
            switch change {
            case let .create(destination, body, time, draft, attachments):
                let address = ComposerDraftAddress(
                    conversation: destination.conversation,
                    thread: destination.thread
                )
                if !attachments.isEmpty {
                    return try await backend.scheduleWithAttachments(
                        in: address, body: body, attachments: attachments, at: time, converting: draft
                    )
                }
                if let draft {
                    guard draft.id.address == address
                    else { throw ChatError.decoding("Invalid draft destination.") }
                    return try await backend.scheduleSavedDraft(draft, body: body, at: time)
                }
                return try await backend.scheduleMessage(
                    in: destination.conversation, thread: destination.thread, body: body, at: time
                )
            case let .edit(address, body):
                return try await backend.editScheduledMessage(address, body: body)
            case let .move(address, time):
                return try await backend.rescheduleMessage(address, at: time)
            case let .sendNow(address):
                try await backend.sendScheduledMessageNow(address)
                return nil
            case let .cancel(address):
                try await backend.cancelScheduledMessage(address)
                return nil
            }
        }
    }

    private func inScheduledSession<Value: Sendable>(
        _ perform: @Sendable (any ChatBackend) async throws -> Value
    ) async throws -> Value {
        let generation = managementGeneration
        try Task.checkCancellation()
        let value = try await perform(backend)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return value
    }
}
