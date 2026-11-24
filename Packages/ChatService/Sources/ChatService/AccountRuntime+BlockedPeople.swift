import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchBlockedPeople(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canManageBlockedPeople else { throw ServiceFailure.unsupportedOperation }
        if request.operation == GetBlockedPeople.operation {
            _ = try request.decodePayload(GetBlockedPeople.self)
            let rows = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
                try await backend.blockedPeople()
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(Self.validateBlockedPeople(rows))
        }
        let payload = try request.decodePayload(UnblockPerson.self)
        guard Self.validBlockedPersonID(payload.person), payload.person != record.selfID else {
            throw ServiceFailure.invalidRequest
        }
        let value = try await performOperation(payload.operationID, request: request, epoch: epoch) {
            let rows = try await backend.unblockPerson(payload.person)
            guard !rows.contains(where: { $0.id == payload.person })
            else { throw ServiceFailure.invalidResponse }
            return try Self.validateBlockedPeople(rows)
        }
        try checkEpoch(epoch)
        worldVersion = UUID()
        reads.directoryCompletedAt = nil
        requestWorldRefresh()
        return value
    }

    private static func validBlockedPersonID(_ id: Member.ID) -> Bool {
        !id.rawValue.isEmpty && id.rawValue.utf8.count <= 4096
    }

    private static func validateBlockedPeople(_ rows: [BlockedPerson]) throws -> [BlockedPerson] {
        guard rows.count <= 4096, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ validBlockedPersonID($0.id) && $0.name.utf8.count <= 4096 }) else {
            throw ServiceFailure.invalidResponse
        }
        return rows
    }
}
