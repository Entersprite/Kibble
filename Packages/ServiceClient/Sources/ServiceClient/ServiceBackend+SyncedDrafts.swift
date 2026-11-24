import ChatAPI
import ChatKit

public extension ServiceBackend {
    func syncedDrafts(
        at address: ComposerDraftAddress?,
        after cursor: String?
    ) async throws -> SyncedDraftPage {
        try await call(GetSyncedDrafts(address: address, cursor: cursor))
    }

    func writeSyncedDraft(
        _ change: SyncedDraftChange,
        operationID: String
    ) async throws -> SyncedDraftWriteResult {
        try await call(WriteSyncedDraft(change: change, operationID: ServiceOperationID(operationID)))
    }
}
