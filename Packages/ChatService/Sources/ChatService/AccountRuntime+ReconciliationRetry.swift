import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    /// Admission pressure and invalidated query snapshots can settle during
    /// startup. Retry bounded read-only work before reporting refresh failure.
    func reconcileBackground(
        resource: ResourceSyncStatus.Resource = .directory, conversation: Conversation.ID? = nil,
        _ operation: () async throws -> Void
    ) async {
        for attempt in 0 ..< 3 {
            guard !Task.isCancelled, !stopped, !quarantinedForSubscription else { return }
            do {
                try await operation()
                return
            } catch {
                if error as? ServiceFailure == .overloaded, attempt < 2 {
                    do {
                        try await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
                    } catch {
                        return
                    }
                } else {
                    await reconciliationFailed(error, resource: resource, conversation: conversation)
                    return
                }
            }
        }
    }
}
