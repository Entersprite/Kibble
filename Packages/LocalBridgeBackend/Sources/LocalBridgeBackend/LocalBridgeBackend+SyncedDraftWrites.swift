import ChatKit
import GChatBridgeCore

public extension LocalBridgeBackend {
    func writeSyncedDraft(
        _ change: SyncedDraftChange,
        operationID _: String
    ) async throws -> SyncedDraftWriteResult {
        try change.validate(capabilities: capabilities)
        guard draftMutations.insert(change.address).inserted else {
            throw ChatError.unknown("This composer already has a draft change in progress.")
        }
        defer { draftMutations.remove(change.address) }

        let (client, generation) = try await unsentMessageClient()
        let id = try UnsentMessageMapping.wireID(
            address: change.address,
            recordID: change.previous?.id.record ?? ScheduledMessageRequests.makeQueueID()
        )
        let record: UnsentMessage? = if let body = change.body {
            try await makeDraftRecord(id, body: body, address: change.address, using: client)
        } else {
            nil
        }
        try checkManagementGeneration(generation)
        let current = try await currentSyncedDraft(at: change.address, using: client, generation: generation)
        if record == nil && current == nil {
            return SyncedDraftWriteResult(applied: true, current: nil)
        }
        guard change.matches(current), record == nil || current?.canRestore != false else {
            return SyncedDraftWriteResult(applied: false, current: current)
        }
        if let record {
            if current?.body == change.body {
                return SyncedDraftWriteResult(applied: true, current: current)
            }
            return try await saveDraft(
                record,
                at: change.address,
                creating: current == nil,
                using: client,
                generation: generation
            )
        }
        return try await clearDraft(id, at: change.address, using: client, generation: generation)
    }
}

extension LocalBridgeBackend {
    func currentSyncedDraft(
        at address: ComposerDraftAddress, using client: ProtoAPIClient, generation: Int
    ) async throws -> SyncedDraft? {
        let page = try await readSyncedDrafts(at: address, after: nil, using: client, generation: generation)
        guard page.nextCursor == nil, page.drafts.count <= 1 else {
            throw ChatError.decoding("The service returned multiple drafts for this composer.")
        }
        return page.drafts.first
    }
}

private extension LocalBridgeBackend {
    func makeDraftRecord(
        _ id: UnsentMessageId, body: ComposedMessage, address: ComposerDraftAddress,
        using client: ProtoAPIClient
    ) async throws -> UnsentMessage {
        let reference = try UnsentMessageMapping.reference(body.content?.quote, in: address.conversation)
        let formats = try MessageContentMapping.annotations(body.content?.formatting ?? [], text: body.text)
        let emoji = try MessageContentMapping.emojiAnnotations(
            body.content?.customEmoji ?? [],
            text: body.text
        )
        let mentions = await mentionAnnotations(body.mentions, using: client)
        return SyncedDraftRequests.content(
            id: id, text: body.text, annotations: formats + emoji + mentions, reference: reference
        )
    }

    func saveDraft(
        _ record: UnsentMessage, at address: ComposerDraftAddress, creating: Bool,
        using client: ProtoAPIClient, generation: Int
    ) async throws -> SyncedDraftWriteResult {
        var failure: APIFailure?
        var response: WriteUnsentMessageResponse?
        do {
            response = if creating {
                try await client.call(.createUnsentMessage, SyncedDraftRequests.create(record))
            } else {
                try await client.call(.updateUnsentMessage, SyncedDraftRequests.edit(record))
            }
        } catch let error as APIFailure {
            failure = error
        }
        try checkManagementGeneration(generation)
        let identity = SyncedDraft.ID(address: address, record: record.id.localID)
        if let response, response.message.hasID, response.message.id != record.id {
            throw ChatError.decoding("The service acknowledged a different draft.")
        }
        if let response, response.revision.hasTimestamp, let draft = try? Self.syncedDraft(response.message),
           Self.confirmsDraft(draft, id: identity, record: record) {
            return SyncedDraftWriteResult(applied: true, current: draft)
        }
        let latest = try await currentSyncedDraft(at: address, using: client, generation: generation)
        if let latest, Self.confirmsDraft(latest, id: identity, record: record) {
            return SyncedDraftWriteResult(applied: true, current: latest)
        }
        if creating, let latest, latest.id != identity {
            return SyncedDraftWriteResult(applied: false, current: latest)
        }
        if let failure {
            throw Self.chatError(fromAPI: failure, call: "saving a draft")
        }
        throw ChatError.decoding("The service did not confirm the draft change.")
    }

    static func confirmsDraft(_ draft: SyncedDraft, id: SyncedDraft.ID, record: UnsentMessage) -> Bool {
        draft.id == id && draft.changeToken == record.clientSyncValue && draft.body.text == record.text
    }

    func clearDraft(
        _ id: UnsentMessageId, at address: ComposerDraftAddress, using client: ProtoAPIClient, generation: Int
    ) async throws -> SyncedDraftWriteResult {
        let failure: APIFailure?
        do {
            _ = try await client.call(.deleteUnsentMessage, ScheduledMessageRequests.cancel(id))
            failure = nil
        } catch let error as APIFailure {
            failure = error
        }
        try checkManagementGeneration(generation)
        let latest = try await currentSyncedDraft(at: address, using: client, generation: generation)
        if latest?.id.record != id.localID {
            return SyncedDraftWriteResult(applied: true, current: latest)
        }
        if let failure {
            throw Self.chatError(fromAPI: failure, call: "clearing a draft")
        }
        throw ChatError.decoding("The service did not confirm the draft was cleared.")
    }
}
