import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func readSyncedDrafts(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canReadSyncedDrafts else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(GetSyncedDrafts.self)
        guard Self.validDraftAddress(payload.address), Self.validDraftIdentifier(payload.cursor) else {
            throw ServiceFailure.invalidRequest
        }
        let page = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            try await backend.syncedDrafts(at: payload.address, after: payload.cursor)
        }
        try checkEpoch(epoch)
        guard page.drafts.count <= 30, Set(page.drafts.map(\.id)).count == page.drafts.count,
              Self.validDraftIdentifier(page.nextCursor),
              page.nextCursor == nil || page.nextCursor != payload.cursor,
              page.drafts.allSatisfy({ Self.validDraft($0, in: payload.address) }) else {
            throw ServiceFailure.invalidResponse
        }
        return try ServiceCodec.value(page)
    }

    func writeSyncedDraft(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canWriteSyncedDrafts else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(WriteSyncedDraft.self)
        let change = payload.change
        guard ClientOperationID.createdAt(payload.operationID.rawValue) != nil,
              Self.validDraftAddress(change.address),
              change.previous.map({ Self.validDraft($0, in: change.address) }) ?? true else {
            throw ServiceFailure.invalidRequest
        }
        try change.validate(capabilities: capabilities)
        let result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
            let result = try await backend.writeSyncedDraft(change, operationID: payload.operationID.rawValue)
            guard Self.validDraftWrite(result, for: change) else { throw ServiceFailure.invalidResponse }
            return result
        }
        try checkEpoch(epoch)
        return result
    }

    private nonisolated static func validDraftWrite(
        _ result: SyncedDraftWriteResult, for change: SyncedDraftChange
    ) -> Bool {
        guard result.current.map({ validDraft($0, in: change.address) }) ?? true else { return false }
        guard result.applied else { return true }
        guard let body = change.body else { return result.current?.id != change.previous?.id }
        guard let saved = result.current, saved.body.text == body.text else { return false }
        return change.previous == nil || saved.id == change.previous?.id
    }

    nonisolated static func validDraft(
        _ draft: SyncedDraft,
        in scope: ComposerDraftAddress?
    ) -> Bool {
        let id = draft.id
        return validDraftIdentifier(id.record) && validDraftAddress(id.address)
            && validDraftIdentifier(draft.changeToken)
            && (scope == nil || id.address == scope)
            && (draft.body.content?.quote?.conversation ?? id.address.conversation) == id.address.conversation
    }

    private nonisolated static func validDraftAddress(_ address: ComposerDraftAddress?) -> Bool {
        validDraftIdentifier(address?.conversation.rawValue) &&
            validDraftIdentifier(address?.thread?.rawValue)
    }

    private nonisolated static func validDraftIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 4096
    }
}
