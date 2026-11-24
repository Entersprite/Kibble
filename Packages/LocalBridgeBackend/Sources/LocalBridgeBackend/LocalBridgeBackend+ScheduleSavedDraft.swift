import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func scheduleSavedDraft(
        _ draft: SyncedDraft, body: ComposedMessage, at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        try await convertDraftToSchedule(draft, body: body, attachments: [], at: deliveryTime)
    }

    internal func convertDraftToSchedule(
        _ draft: SyncedDraft, body: ComposedMessage, attachments: [ChatKit.Attachment], at deliveryTime: Date
    ) async throws -> ScheduledMessage {
        let address = draft.id.address
        guard capabilities.canScheduleSavedDraft, draft.canRestore else {
            throw ChatError.unsupported(capability: "scheduleSavedDraft")
        }
        guard draftMutations.insert(address).inserted else {
            throw ChatError.unknown("This composer already has a draft change in progress.")
        }
        defer { draftMutations.remove(address) }

        let (client, generation) = try await unsentMessageClient()
        let queueAddress = ScheduledMessageAddress(
            conversation: address.conversation, thread: address.thread, queueID: draft.id.record
        )
        let id = try UnsentMessageMapping.wireID(address: address, recordID: draft.id.record)
        let annotations = try await scheduledAnnotations(
            body, in: address.conversation, using: client, generation: generation, attachments: attachments
        )
        let reference = try await scheduledReference(body, in: address.conversation, generation: generation)
        let request = try ScheduledMessageRequests.convertDraft(
            id, text: body.text, annotations: annotations, reference: reference, deliveryTime: deliveryTime
        )
        let baseline = SyncedDraftChange(address: address, previous: draft, body: nil)
        let current = try await currentSyncedDraft(at: address, using: client, generation: generation)
        guard current?.canRestore == true, baseline.matches(current) else {
            throw ChatError.unknown("The saved draft changed before it could be scheduled.")
        }

        let scheduled = try await confirmConvertedDraft(
            request, at: queueAddress, using: client, generation: generation,
            uploadIDs: attachments.isEmpty ? nil : attachments.map(\.id)
        )
        guard scheduled.body.text == body.text, Self.sameScheduleTime(scheduled.deliveryTime, deliveryTime),
              try await currentSyncedDraft(at: address, using: client, generation: generation)?.id != draft.id
        else {
            throw ChatError.decoding("The service did not confirm conversion of the saved draft.")
        }
        return scheduled
    }
}

private extension LocalBridgeBackend {
    func confirmConvertedDraft(
        _ request: UpdateUnsentMessageRequest, at address: ScheduledMessageAddress,
        using client: ProtoAPIClient, generation: Int, uploadIDs: [String]?
    ) async throws -> ScheduledMessage {
        do {
            let response = try await client.call(.updateUnsentMessage, request)
            return try await confirmedSchedule(
                response,
                address: address,
                using: client,
                generation: generation,
                preservingUploads: uploadIDs,
                preservingForward: request.message.reference
            )
        } catch let failure as APIFailure {
            try checkManagementGeneration(generation)
            if let recovered = try? await readScheduledRecord(
                   address,
                   using: client,
                   generation: generation
               ), ScheduledMessageMapping.preservesForward(request.message.reference, in: recovered),
               uploadIDs == nil || ScheduledMessageMapping.editableUploads(in: recovered)
                   .map(\.uploadMetadata.attachmentToken) == uploadIDs {
                return try ScheduledMessageMapping.message(recovered)
            }
            throw Self.chatError(fromAPI: failure, call: "scheduling the saved draft")
        }
    }
}
