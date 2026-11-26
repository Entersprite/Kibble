import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func scheduledMessages(after cursor: String?) async throws -> ScheduledMessagesPage {
        let (client, generation) = try await unsentMessageClient()
        let page = try await readScheduledPage(after: cursor, using: client, generation: generation)
        return try ScheduledMessagesPage(
            messages: page.records.map(ScheduledMessageMapping.message), nextCursor: page.nextCursor
        )
    }

    func scheduleMessage(
        in conversation: Conversation.ID, thread: MessageThread.ID?, body: ComposedMessage,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try await scheduleNewMessage(
            at: ComposerDraftAddress(conversation: conversation, thread: thread),
            body: body, attachments: [], deliveryTime: deliveryTime
        )
    }

    func scheduleWithAttachments(
        in address: ComposerDraftAddress, body: ComposedMessage, attachments: [ChatKit.Attachment],
        at deliveryTime: Date, converting draft: SyncedDraft?
    ) async throws -> ScheduledMessage {
        guard capabilities.canScheduleAttachments, !attachments.isEmpty else {
            throw ChatError.unsupported(capability: "scheduleAttachments")
        }
        if let draft {
            guard draft.id.address == address else { throw ChatError.decoding("Invalid draft destination.") }
            return try await convertDraftToSchedule(
                draft,
                body: body,
                attachments: attachments,
                at: deliveryTime
            )
        }
        return try await scheduleNewMessage(
            at: address,
            body: body,
            attachments: attachments,
            deliveryTime: deliveryTime
        )
    }

    private func scheduleNewMessage(
        at destination: ComposerDraftAddress, body: ComposedMessage, attachments: [ChatKit.Attachment],
        deliveryTime: Date
    ) async throws -> ScheduledMessage {
        let (client, generation) = try await unsentMessageClient()
        let conversation = destination.conversation
        let address = ScheduledMessageAddress(
            conversation: conversation, thread: destination.thread,
            queueID: ScheduledMessageRequests.makeQueueID()
        )
        let id = try ScheduledMessageMapping.wireID(address)
        let annotations = try await scheduledAnnotations(
            body,
            in: conversation,
            using: client,
            generation: generation,
            attachments: attachments
        )
        let reference = try await scheduledReference(body, in: conversation, generation: generation)
        let request = try ScheduledMessageRequests.create(
            id, text: body.text, annotations: annotations, reference: reference, deliveryTime: deliveryTime
        )
        do {
            let reply = try await client.call(.createUnsentMessage, request)
            let message = try await confirmedSchedule(
                reply,
                address: address,
                using: client,
                generation: generation,
                preservingUploads: attachments.isEmpty ? nil : attachments.map(\.id),
                preservingForward: reference
            )
            guard message.body.text == body.text,
                  Self.sameScheduleTime(message.deliveryTime, deliveryTime) else {
                throw ChatError.decoding("The service returned a different scheduled message.")
            }
            return message
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "scheduling a message")
        }
    }

    func editScheduledMessage(
        _ address: ScheduledMessageAddress,
        body: ComposedMessage
    ) async throws -> ScheduledMessage {
        try beginScheduledMutation(address)
        defer { scheduledMutations.remove(address) }
        let (client, generation) = try await unsentMessageClient()
        let id = try ScheduledMessageMapping.wireID(address)
        let existing = try await readScheduledRecord(address, using: client, generation: generation)
        let message = try ScheduledMessageMapping.message(existing)
        guard message.canEditBody,
              body.content?.quote == nil || body.content?.quote?.id == message.body.content?.quote?.id
        else { throw ChatError.unsupported(capability: "editing this scheduled message") }
        guard message.hasContentWithoutCaption ||
            !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.decoding("Enter a message before saving.")
        }
        let annotations = try await scheduledAnnotations(
            body, in: address.conversation, using: client, generation: generation, editingCaption: true
        )
        let uploads = ScheduledMessageMapping.editableUploads(in: existing)
        let request = try ScheduledMessageRequests.edit(
            id, text: body.text, annotations: annotations + uploads
        )
        do {
            let reply = try await client.call(.updateUnsentMessage, request)
            let updated = try await confirmedSchedule(
                reply,
                address: address,
                using: client,
                generation: generation,
                preservingUploads: uploads.isEmpty ? nil : uploads.map(\.uploadMetadata.attachmentToken),
                preservingForward: ScheduledMessageMapping.forward(in: existing)
            )
            guard updated.body.text == body.text else {
                throw ChatError.decoding("The service did not confirm the scheduled text edit.")
            }
            return updated
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "editing a scheduled message")
        }
    }

    func rescheduleMessage(
        _ address: ScheduledMessageAddress,
        at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try beginScheduledMutation(address)
        defer { scheduledMutations.remove(address) }
        let (client, generation) = try await unsentMessageClient()
        let id = try ScheduledMessageMapping.wireID(address)
        let existing = try await readScheduledRecord(address, using: client, generation: generation)
        let request = try ScheduledMessageRequests.reschedule(id, deliveryTime: deliveryTime)
        do {
            let reply = try await client.call(.updateUnsentMessage, request)
            let updated = try await confirmedSchedule(
                reply,
                address: address,
                using: client,
                generation: generation,
                preservingForward: ScheduledMessageMapping.forward(in: existing)
            )
            guard Self.sameScheduleTime(updated.deliveryTime, deliveryTime) else {
                throw ChatError.decoding("The service did not confirm the new delivery time.")
            }
            return updated
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "rescheduling a message")
        }
    }

    func cancelScheduledMessage(_ address: ScheduledMessageAddress) async throws {
        try beginScheduledMutation(address)
        defer { scheduledMutations.remove(address) }
        let (client, generation) = try await unsentMessageClient()
        let id = try ScheduledMessageMapping.wireID(address)
        _ = try await readScheduledRecord(address, using: client, generation: generation)
        let response: DeleteUnsentMessageResponse
        do {
            response = try await client.call(.deleteUnsentMessage, ScheduledMessageRequests.cancel(id))
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "canceling a scheduled message")
        }
        try checkManagementGeneration(generation)
        guard response.revision.hasTimestamp else {
            throw ChatError.decoding("The service did not confirm cancellation.")
        }
    }

    func sendScheduledMessageNow(_ address: ScheduledMessageAddress) async throws {
        try beginScheduledMutation(address)
        defer { scheduledMutations.remove(address) }
        let (client, generation) = try await unsentMessageClient()
        let record = try await readScheduledRecord(address, using: client, generation: generation)
        let confirmed: Bool
        do {
            switch try ScheduledMessageRequests.sendNow(record) {
            case let .topic(request):
                let response = try await client.call(.createTopic, request)
                confirmed = response.hasTopic && response.topic.id.topicID == request.topicAndMessageID
                    && (!response.topic.id.hasGroupID || response.topic.id.groupID == request.groupID)
            case let .reply(request):
                let response = try await client.call(.createMessage, request)
                confirmed = response.hasMessage && response.message.id.messageID == request.messageID
                    && response.message.id.parentID == request.parentID
            }
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "sending a scheduled message now")
        }
        try checkManagementGeneration(generation)
        guard confirmed else { throw ChatError.decoding("The service did not confirm delivery.") }
    }
}

extension LocalBridgeBackend {
    private func beginScheduledMutation(_ address: ScheduledMessageAddress) throws {
        guard scheduledMutations.insert(address).inserted else {
            throw ChatError.unknown("This scheduled message already has a change in progress.")
        }
    }

    private func readScheduledPage(
        after cursor: String?, in group: GroupId? = nil, using client: ProtoAPIClient, generation: Int
    ) async throws -> (records: [UnsentMessage], nextCursor: String?) {
        let reply: ListUnsentMessagesResponse
        do {
            reply = try await client.call(
                .listUnsentMessages,
                ScheduledMessageRequests.list(after: cursor, in: group)
            )
        } catch let failure as APIFailure {
            throw Self.chatError(fromAPI: failure, call: "loading scheduled messages")
        }
        try checkManagementGeneration(generation)
        let next = reply.hasNextCursor && !reply.nextCursor.isEmpty ? reply.nextCursor : nil
        let identities = reply.messages.compactMap { ScheduledMessageMapping.address($0.id) }
        guard reply.hasRevision, reply.messages.count <= 30, next == nil || next != cursor,
              identities.count == reply.messages.count, Set(identities).count == identities.count,
              reply.messages.allSatisfy({ $0.unsentType == 1 && (group == nil || $0.id.groupID == group) })
        else {
            throw ChatError.decoding("The service returned an invalid scheduled messages page.")
        }
        return (reply.messages, next)
    }

    func readScheduledRecord(
        _ address: ScheduledMessageAddress, using client: ProtoAPIClient, generation: Int
    ) async throws -> UnsentMessage {
        let group = try ScheduledMessageMapping.wireID(address).groupID
        var cursor: String?
        var visited: Set<String> = []
        repeat {
            let page = try await readScheduledPage(
                after: cursor,
                in: group,
                using: client,
                generation: generation
            )
            if let record = page.records.first(where: { ScheduledMessageMapping.address($0.id) == address }) {
                return record
            }
            cursor = page.nextCursor
            if let cursor, !visited.insert(cursor).inserted {
                throw ChatError.decoding("The service repeated a scheduled messages page.")
            }
        } while cursor != nil
        throw ChatError.decoding("This scheduled message is no longer in the queue.")
    }

    func confirmedSchedule(
        _ response: WriteUnsentMessageResponse, address: ScheduledMessageAddress,
        using client: ProtoAPIClient, generation: Int, preservingUploads: [String]? = nil,
        preservingForward: UnsentMessageReference? = nil
    ) async throws -> ScheduledMessage {
        try checkManagementGeneration(generation)
        if response.message.hasID, ScheduledMessageMapping.address(response.message.id) != address {
            throw ChatError.decoding("The service returned a different scheduled message.")
        }
        func preservesAttachments(_ record: UnsentMessage) -> Bool {
            guard let preservingUploads else { return true }
            return ScheduledMessageMapping.editableUploads(in: record)
                .map(\.uploadMetadata.attachmentToken) == preservingUploads
        }
        if response.revision.hasTimestamp, preservesAttachments(response.message),
           ScheduledMessageMapping.preservesForward(preservingForward, in: response.message),
           let confirmed = try? ScheduledMessageMapping.message(response.message) {
            return confirmed
        }
        let refreshed = try await readScheduledRecord(address, using: client, generation: generation)
        guard preservesAttachments(refreshed) else {
            throw ChatError.decoding("The service did not confirm the scheduled attachments.")
        }
        guard ScheduledMessageMapping.preservesForward(preservingForward, in: refreshed) else {
            throw ChatError.decoding("The service did not confirm the scheduled forward.")
        }
        return try ScheduledMessageMapping.message(refreshed)
    }

    func scheduledReference(
        _ body: ComposedMessage, in conversation: Conversation.ID, generation: Int
    ) async throws -> UnsentMessageReference? {
        guard let source = body.content?.forwardSource else {
            return try UnsentMessageMapping.reference(body.content?.quote, in: conversation)
        }
        let original = try await verifyForwardSource(source)
        try checkManagementGeneration(generation)
        let target = Self.forwardTarget(original)
        return UnsentMessageMapping.reference(target, type: target.referenceType)
    }

    func scheduledAnnotations(
        _ body: ComposedMessage, in conversation: Conversation.ID, using client: ProtoAPIClient,
        generation: Int, attachments: [ChatKit.Attachment] = [], editingCaption: Bool = false
    ) async throws -> [Annotation] {
        try body.validateForScheduling(
            in: conversation, capabilities: capabilities, hasAttachments: !attachments.isEmpty,
            editingCaption: editingCaption
        )
        let formats = try MessageContentMapping.annotations(body.content?.formatting ?? [], text: body.text)
        let emoji = try MessageContentMapping.emojiAnnotations(
            body.content?.customEmoji ?? [],
            text: body.text
        )
        let mentions = await mentionAnnotations(body.mentions, using: client)
        try checkManagementGeneration(generation)
        return formats + emoji + mentions + Self.uploadAnnotations(attachments, uploaded: uploadedMetadata)
    }

    static func sameScheduleTime(_ actual: Date, _ requested: Date) -> Bool {
        abs(actual.timeIntervalSince(requested)) <= 0.001
    }
}
