import ChatAPI
import ChatKit

public extension ServiceBackend {
    func invokeCardAction(_ action: AppCardActionRequest) async throws -> AppCardActionResult {
        try await call(InvokeCardAction(
            action: action,
            operationID: ServiceOperationID(ClientOperationID.make())
        ))
    }
}
