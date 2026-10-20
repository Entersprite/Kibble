import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func checkEpoch(_ epoch: UUID) throws {
        guard !quarantinedForSubscription else { throw ServiceFailure.accountCleanupPending }
        guard !stopped, currentEpoch == epoch else { throw ServiceFailure.accountDisabled }
        try Task.checkCancellation()
    }

    func handle(_ request: ServiceRequest, context: ServiceSessionContext? = nil) async throws -> JSONValue {
        guard !quarantinedForSubscription else { throw ServiceFailure.accountCleanupPending }
        guard !stopped else { throw ServiceFailure.accountDisabled }
        guard requests.count + binaryRequests.count < 32 else { throw ServiceFailure.overloaded }
        let id = UUID()
        let epoch = currentEpoch
        let work = Task { try await dispatch(request, context: context, epoch: epoch) }
        requests[id] = work
        defer { requests[id] = nil }
        return try await withTaskCancellationHandler {
            do {
                return try await work.value
            } catch {
                if quarantinedForSubscription,
                   error is CancellationError || error as? ServiceFailure == .accountDisabled {
                    throw ServiceFailure.accountCleanupPending
                }
                if error as? ChatError == .sessionExpired {
                    await quarantine(.authentication)
                    throw ServiceFailure.accountCleanupPending
                }
                throw error
            }
        } onCancel: {
            work.cancel()
        }
    }

    private func dispatch(
        _ request: ServiceRequest, context: ServiceSessionContext?, epoch: UUID
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        if let deadline = request.header.deadline,
           deadline <= Date() {
            throw ServiceFailure.deadlineExceeded
        }
        switch request.operation {
        case AttachAccountClient.operation, DetachAccountClient.operation:
            guard let context else { throw ServiceFailure.notAuthorized }
            return try dispatchClientAttachment(request, context: context)
        case ReadEvents.operation:
            let payload = try request.decodePayload(ReadEvents.self)
            return try ServiceCodec.value(storage.readEvents(after: payload.cursor, limit: payload.limit))
        case GetProjectionCheckpoint.operation:
            _ = try request.decodePayload(GetProjectionCheckpoint.self)
            return try ServiceCodec.value(storage.checkpoint())
        case GetOperation.operation:
            let payload = try request.decodePayload(GetOperation.self)
            guard let result = try storage.operation(payload.operationID)
            else { throw ServiceFailure.operationUnknown }
            return try ServiceCodec.value(result)
        default: break
        }
        guard let backend else { throw ServiceFailure.overloaded }
        try checkEpoch(epoch)
        return try await dispatchProvider(request, backend: backend, context: context, epoch: epoch)
    }
}
