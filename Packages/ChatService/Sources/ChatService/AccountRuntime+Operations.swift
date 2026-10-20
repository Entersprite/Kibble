import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func performOperation(
        _ id: ServiceOperationID, request: ServiceRequest, epoch: UUID,
        authorize: () throws -> Void = {},
        perform: @Sendable () async throws -> some Codable & Sendable
    ) async throws -> JSONValue {
        let permit = UUID()
        try await providerWork.acquire(permit, owner: instanceID)
        do {
            try checkEpoch(epoch)
            let value = try await performAdmittedOperation(
                id,
                request: request,
                epoch: epoch,
                authorize: authorize,
                perform: perform
            )
            await providerWork.release(permit)
            return value
        } catch {
            await providerWork.release(permit)
            throw error
        }
    }

    private func performAdmittedOperation(
        _ id: ServiceOperationID, request: ServiceRequest, epoch: UUID,
        authorize: () throws -> Void,
        perform: @Sendable () async throws -> some Codable & Sendable
    ) async throws -> JSONValue {
        let operation = try storage.reserve(id, request: request)
        switch operation.state {
        case "succeeded":
            guard let result = operation.result else { throw ServiceFailure.invalidResponse }
            return result
        case "failed": throw operation.failure ?? ServiceFailure.internalFailure
        case "accepted": break
        default: throw ServiceFailure.operationUnknown
        }
        try checkEpoch(epoch)
        do {
            try authorize()
        } catch {
            if error as? ServiceFailure == .privacyDenied {
                try storage.finish(ServiceOperation(id: id, state: "failed", failure: .privacyDenied))
            }
            throw error
        }
        try storage.finish(ServiceOperation(id: id, state: "dispatching"))
        do {
            let result = try await ServiceCodec.value(perform())
            try storage.finish(ServiceOperation(id: id, state: "succeeded", result: result))
            return result
        } catch {
            if error as? ChatError == .sessionExpired {
                await quarantine(.authentication)
            }
            // Once dispatch starts, an error alone does not establish non-execution.
            try storage.finish(ServiceOperation(id: id, state: "unknown", failure: serviceFailure(error)))
            throw ServiceFailure.operationUnknown
        }
    }
}
