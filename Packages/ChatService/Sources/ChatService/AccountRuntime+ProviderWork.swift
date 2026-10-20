import Foundation

extension AccountRuntime {
    func withProviderWork<Value: Sendable>(
        epoch: UUID, _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        try await providerWork.acquire(id, owner: instanceID)
        do {
            try checkEpoch(epoch)
            let value = try await operation()
            await providerWork.release(id)
            return value
        } catch {
            await providerWork.release(id)
            throw error
        }
    }
}
