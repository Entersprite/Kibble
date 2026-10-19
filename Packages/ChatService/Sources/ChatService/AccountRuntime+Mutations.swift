import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchMutations(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case SendHint.operation:
            let payload = try request.decodePayload(SendHint.self)
            guard SendHint.accepts(payload.command) else { throw ServiceFailure.invalidRequest }
            try authorizePrivacy(payload.command)
            try checkEpoch(epoch)
            try await backend.send(payload.command)
            try checkEpoch(epoch)
            return try ServiceCodec.value(ServiceUnit())
        case OpenDirectConversation.operation:
            let payload = try request.decodePayload(OpenDirectConversation.self)
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.openDirectConversation(with: payload.memberID)
            }
        case CreateConversation.operation:
            let payload = try request.decodePayload(CreateConversation.self)
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.createConversation(payload.draft)
            }
        case MutateConversation.operation:
            let payload = try request.decodePayload(MutateConversation.self)
            return try await performOperation(payload.operationID, request: request, epoch: epoch) {
                try await backend.mutateConversation(
                    payload.mutation,
                    in: payload.conversationID,
                    operationID: payload.operationID.rawValue,
                    expectedRevision: payload.expectedRevision
                )
            }
        case SendCommand.operation:
            let payload = try request.decodePayload(SendCommand.self)
            guard !SendHint.accepts(payload.command) else { throw ServiceFailure.invalidRequest }
            let result = try await performOperation(
                payload.operationID, request: request, epoch: epoch,
                authorize: { try authorizePrivacy(payload.command) }, perform: {
                    try await { try await backend.send(payload.command); return ServiceUnit() }()
                }
            )
            _ = result
            guard let operation = try storage.operation(payload.operationID)
            else { throw ServiceFailure.operationUnknown }
            return try ServiceCodec.value(operation)
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
