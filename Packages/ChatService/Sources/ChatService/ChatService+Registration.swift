import ChatAPI
import Foundation

public extension ChatService {
    /// Host-only admission after credential validation; no client DTO grants this authority.
    func registerVerified(_ record: AccountRecord) async throws {
        var record = record
        if record.position == nil {
            record.position = nextAccountPosition()
        }
        guard restoredForSubscriptions, !shuttingDown, !record.isRemoving,
              record.authenticationState == nil else { throw ServiceFailure.invalidRequest }
        guard records[record.id] == nil,
              !records.values
              .contains(where: { $0.principalID == record.principalID && $0.selfID == record.selfID }) else {
            throw ServiceFailure.operationConflict
        }
        try registry.save(record)
        records[record.id] = record
        accountStateChanged()
        if record.isEnabled {
            let runtime = try makeRuntime(record)
            runtimes[record.id] = runtime
            await runtime.start()
        }
    }
}
