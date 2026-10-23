import ChatKit
import Foundation

public extension SyncEngine {
    /// One page of the account's retained call records, from the backend's
    /// optional port. Nothing is written: the list is a view over records the
    /// account already keeps, and the cursor is the backend's, passed back
    /// verbatim. A page that answers after `stop()` is dropped.
    func callHistory(_ query: CallHistoryQuery) async throws -> CallHistoryPage {
        let generation = managementGeneration
        try Task.checkCancellation()
        guard backend.capabilities.canReadCallHistory, let history = backend as? any CallHistoryBackend
        else { throw ChatError.unsupported(capability: "callHistory") }
        let page = try await history.callHistory(query)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return page
    }
}
