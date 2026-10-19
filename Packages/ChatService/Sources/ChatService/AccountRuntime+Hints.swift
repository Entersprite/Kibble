import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchHint(
        _ request: ServiceRequest, backend: any ChatBackend, context: ServiceSessionContext?, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(SendHint.self)
        guard SendHint.accepts(payload.command) else { throw ServiceFailure.invalidRequest }
        guard try ServiceCodec.encode(payload).count <= 64 * 1024 else { throw ServiceFailure.frameTooLarge }
        guard let context else { throw ServiceFailure.notAuthorized }
        let key = try validateAttachment(payload.attachmentID, context: context)
        guard let deadline = request.header.deadline, deadline.timeIntervalSinceNow > 0,
              deadline.timeIntervalSinceNow <= 60, let raw = payload.sequence,
              let sequence = UInt64(raw), sequence > 0, String(sequence) == raw
        else { throw ServiceFailure.invalidRequest }
        try checkEpoch(epoch)
        if case .loadMembers = payload.command {
            try await backend.send(payload.command)
        } else {
            try updateClientInterest(payload.command, key: key, sequence: sequence, backend: backend)
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(ServiceUnit())
    }
}
