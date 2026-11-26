import ChatKit
import Foundation

public extension SyncEngine {
    func invokeCardAction(_ action: AppCardActionRequest) async throws -> AppCardActionResult {
        let generation = managementGeneration
        try Task.checkCancellation()
        guard backend.capabilities.canInvokeCardActions
        else { throw ChatError.unsupported(capability: "cardActions") }
        let result = try await backend.invokeCardAction(action)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return result
    }
}
