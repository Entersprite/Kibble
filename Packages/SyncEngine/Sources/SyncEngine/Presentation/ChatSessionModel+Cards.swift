import ChatKit
import Foundation

public extension ChatSessionModel {
    func invokeCardAction(_ action: AppCardActionRequest) async throws -> AppCardActionResult {
        try await engine.invokeCardAction(action)
    }
}
