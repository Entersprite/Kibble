import ChatKit

extension LocalBridgeBackend {
    /// Trace the provider boundary before the service deliberately hides error payloads.
    func managementStep<Value>(_ step: String, perform: () async throws -> Value) async throws -> Value {
        do {
            let value = try await perform()
            recordManagementStage(step, failure: nil)
            return value
        } catch {
            recordManagementStage(step, failure: ManagementFailureKind.of(error))
            throw error
        }
    }
}
