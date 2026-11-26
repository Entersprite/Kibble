import ChatKit

extension SyncEngine {
    func syncedComposerDraft(at address: ComposerDraftAddress) async throws -> SyncedDraft? {
        let generation = managementGeneration
        let page = try await backend.syncedDrafts(at: address, after: nil)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        guard page.nextCursor == nil, page.drafts.count <= 1,
              page.drafts.first.map({ $0.id.address == address }) ?? true else {
            throw ChatError.decoding("This composer has more than one saved draft.")
        }
        return page.drafts.first
    }

    func writeComposerDraft(
        _ change: SyncedDraftChange, operationID: String
    ) async throws -> SyncedDraftWriteResult {
        let generation = managementGeneration
        try Task.checkCancellation()
        let result = try await backend.writeSyncedDraft(change, operationID: operationID)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return result
    }
}

public extension ChatSessionModel {
    func syncedComposerDraft(at address: ComposerDraftAddress) async throws -> SyncedDraft? {
        try await engine.syncedComposerDraft(at: address)
    }

    func writeComposerDraft(
        _ change: SyncedDraftChange, operationID: String
    ) async throws -> SyncedDraftWriteResult {
        try await engine.writeComposerDraft(change, operationID: operationID)
    }
}
