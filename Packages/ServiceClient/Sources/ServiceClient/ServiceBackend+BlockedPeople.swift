import ChatAPI
import ChatKit

public extension ServiceBackend {
    func blockedPeople() async throws -> [BlockedPerson] {
        try await call(GetBlockedPeople())
    }

    func unblockPerson(_ id: Member.ID) async throws -> [BlockedPerson] {
        try await call(UnblockPerson(person: id, operationID: ServiceOperationID(ClientOperationID.make())))
    }
}
