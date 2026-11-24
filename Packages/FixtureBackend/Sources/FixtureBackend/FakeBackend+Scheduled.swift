import ChatKit
import Foundation

public extension FakeBackend {
    func scheduledMessages(after cursor: String?) async throws -> ScheduledMessagesPage {
        try requireScheduledMessages()
        let ordered = scheduledQueue.sorted {
            ($0.deliveryTime, $0.id.queueID) < ($1.deliveryTime, $1.id.queueID)
        }
        let start = if let cursor, let index = ordered.firstIndex(where: { $0.id.queueID == cursor }) {
            index + 1
        } else {
            0
        }
        guard cursor == nil || start > 0
        else { throw ChatError.decoding("This scheduled page is unavailable.") }
        let end = min(start + 30, ordered.count)
        let page = Array(ordered[start ..< end])
        return ScheduledMessagesPage(
            messages: page.map(displaySchedule),
            nextCursor: end < ordered.count ? page.last?.id.queueID : nil
        )
    }

    func scheduleMessage(
        in conversation: Conversation.ID, thread: MessageThread.ID?, body: ComposedMessage,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try schedule(
            in: ComposerDraftAddress(conversation: conversation, thread: thread),
            body: body, attachments: [], at: deliveryTime, converting: nil
        )
    }

    func scheduleSavedDraft(
        _ draft: SyncedDraft, body: ComposedMessage, at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try schedule(in: draft.id.address, body: body, attachments: [], at: deliveryTime, converting: draft)
    }

    func scheduleWithAttachments(
        in address: ComposerDraftAddress, body: ComposedMessage, attachments: [Attachment],
        at deliveryTime: Date, converting draft: SyncedDraft?
    ) async throws -> ScheduledMessage {
        try require(capabilities.canScheduleAttachments && !attachments.isEmpty, "scheduleAttachments")
        return try schedule(
            in: address,
            body: body,
            attachments: attachments,
            at: deliveryTime,
            converting: draft
        )
    }

    private func schedule(
        in address: ComposerDraftAddress, body: ComposedMessage, attachments: [Attachment],
        at deliveryTime: Date, converting draft: SyncedDraft?
    ) throws -> ScheduledMessage {
        try validateSchedule(
            in: address.conversation,
            body: body,
            at: deliveryTime,
            hasFiles: !attachments.isEmpty
        )
        if let source = body.content?.forwardSource {
            guard world.messages.contains(where: {
                $0.id == source.id && $0.conversationID == source.conversation
                    && $0.threadID == source.thread && !$0.isDeleted && $0.callStatus == nil
            }) else { throw ChatError.decoding("The original message is unavailable.") }
        }
        if let draft {
            try consumeScheduleDraft(draft, at: address)
        }
        let queueID = draft?.id.record ?? nextIdentifier("fixture-queue-\(world.me.rawValue)")
        return enqueueSchedule(
            at: ScheduledMessageAddress(
                conversation: address.conversation,
                thread: address.thread,
                queueID: queueID
            ),
            body: body, deliveryTime: deliveryTime, attachments: attachments, convertedDraft: draft != nil
        )
    }

    private func consumeScheduleDraft(_ draft: SyncedDraft, at address: ComposerDraftAddress) throws {
        try require(capabilities.canScheduleSavedDraft, "scheduleSavedDraft")
        let scope = world.syncedDrafts.indices.filter { world.syncedDrafts[$0].id.address == address }
        let baseline = SyncedDraftChange(address: address, previous: draft, body: nil)
        guard draft.id.address == address, draft.canRestore, scope.count == 1, let index = scope.first,
              world.syncedDrafts[index].canRestore, baseline.matches(world.syncedDrafts[index]) else {
            throw ChatError.unknown("The saved draft changed before it could be scheduled.")
        }
        world.syncedDrafts.remove(at: index)
    }

    func editScheduledMessage(
        _ address: ScheduledMessageAddress,
        body: ComposedMessage
    ) async throws -> ScheduledMessage {
        let index = try scheduledIndex(address)
        let stored = scheduledQueue[index]
        guard stored.hasContentWithoutCaption ||
            !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.decoding("Enter a message before saving.")
        }
        try body.validateForScheduling(
            in: address.conversation, capabilities: capabilities, editingCaption: true
        )
        var edited = body
        var content = edited.content ?? MessageContent()
        content.quote = stored.body.content?.quote
        content.forwardSource = stored.body.content?.forwardSource
        edited.content = content.isEmpty ? nil : content
        scheduledQueue[index].body = edited
        emitScheduleChange(address)
        return displaySchedule(scheduledQueue[index])
    }

    func rescheduleMessage(
        _ address: ScheduledMessageAddress,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        let index = try scheduledIndex(address)
        guard deliveryTime > now else { throw ChatError.decoding("Choose a future delivery time.") }
        scheduledQueue[index].deliveryTime = deliveryTime
        emitScheduleChange(address)
        return displaySchedule(scheduledQueue[index])
    }

    func cancelScheduledMessage(_ address: ScheduledMessageAddress) async throws {
        try scheduledQueue.remove(at: scheduledIndex(address))
        scheduledAttachments[address] = nil
        emitScheduleChange(address)
    }

    func sendScheduledMessageNow(_ address: ScheduledMessageAddress) async throws {
        try require(capabilities.canSendScheduledMessagesNow, "sendScheduledMessageNow")
        let index = try scheduledIndex(address)
        try sendMessage(
            in: address.conversation, thread: address.thread, body: scheduledQueue[index].body,
            localID: address.queueID, attachments: scheduledAttachments[address] ?? []
        )
        scheduledQueue.remove(at: index)
        scheduledAttachments[address] = nil
        emitScheduleChange(address)
    }
}

private extension FakeBackend {
    func validateSchedule(
        in conversation: Conversation.ID, body: ComposedMessage, at time: Date, hasFiles: Bool
    ) throws {
        try requireScheduledMessages()
        guard world.conversations.contains(where: { $0.id == conversation }), time > now else {
            throw ChatError.decoding("Invalid scheduled message destination or time.")
        }
        try body.validateForScheduling(in: conversation, capabilities: capabilities, hasAttachments: hasFiles)
    }

    func enqueueSchedule(
        at address: ScheduledMessageAddress, body: ComposedMessage, deliveryTime: Date,
        attachments: [Attachment], convertedDraft: Bool
    ) -> ScheduledMessage {
        let message = ScheduledMessage(
            id: address, body: body, deliveryTime: deliveryTime,
            attachmentNames: attachments.isEmpty ? nil : attachments.map(\.name),
            isForward: body.content?.forwardSource == nil ? nil : true
        )
        if !attachments.isEmpty {
            scheduledAttachments[address] = attachments
        }
        scheduledQueue.append(message)
        emitScheduleChange(address, convertedDraft: convertedDraft)
        return displaySchedule(message)
    }

    func displaySchedule(_ stored: ScheduledMessage) -> ScheduledMessage {
        var projected = stored
        projected.body.content?.forwardSource = nil
        if projected.body.content?.isEmpty == true {
            projected.body.content = nil
        }
        return projected
    }

    func emitScheduleChange(_ address: ScheduledMessageAddress, convertedDraft: Bool = false) {
        emit(.unsentMessagesChanged(.init(
            address: ComposerDraftAddress(conversation: address.conversation, thread: address.thread),
            drafts: convertedDraft, scheduled: true
        )))
    }

    func requireScheduledMessages() throws {
        try requireConnected()
        try require(capabilities.canScheduleMessages, "scheduledMessages")
    }

    func scheduledIndex(_ address: ScheduledMessageAddress) throws -> Int {
        try requireScheduledMessages()
        guard let index = scheduledQueue.firstIndex(where: { $0.id == address }) else {
            throw ChatError.decoding("This scheduled message is no longer in the queue.")
        }
        return index
    }
}
