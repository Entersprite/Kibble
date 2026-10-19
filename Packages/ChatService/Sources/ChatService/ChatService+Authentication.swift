import ChatAPI
import ChatKit
import Foundation

extension ChatService {
    func checkAuthentication(_ record: AccountRecord) throws {
        switch record.authenticationState {
        case nil: return
        case "erasing": throw ServiceFailure.accountCleanupPending
        case "required": throw ServiceFailure.authenticationRequired
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    func runtimeFailed(_ id: ConnectedAccountID, generation: String, instanceID: UUID, fault: RuntimeFault) {
        guard !shuttingDown, var record = records[id], !record.isRemoving,
              record.credentialGeneration == generation, runtimes[id]?.instanceID == instanceID,
              maintenance[id] == nil else { return }
        if changing.contains(id) {
            deferredFaults[id] = RuntimeIncident(generation: generation, instanceID: instanceID, fault: fault)
            return
        }
        switch fault {
        case .authentication:
            record.authenticationState = "erasing"
            records[id] = record
            accountStateChanged()
            try? registry.save(record)
            scheduleAuthenticationRecovery(record)
        case .storage:
            maintenance[id] = Task {
                defer { maintenance[id] = nil }
                changing.insert(id)
                defer { finishChange(id) }
                await runtimes[id]?.stop()
                runtimes[id] = nil
            }
        }
    }

    func restoreAuthenticationRecovery() {
        for record in records.values where record.authenticationState == "erasing" && !record.isRemoving {
            scheduleAuthenticationRecovery(record)
        }
    }

    private func scheduleAuthenticationRecovery(_ record: AccountRecord) {
        guard maintenance[record.id] == nil else { return }
        maintenance[record.id] = Task {
            defer { maintenance[record.id] = nil }
            try? await completeAuthenticationRecovery(record.id, generation: record.credentialGeneration)
        }
    }

    private func completeAuthenticationRecovery(_ id: ConnectedAccountID, generation: String) async throws {
        guard !changing.contains(id), var record = records[id], !record.isRemoving,
              record.authenticationState == "erasing", record.credentialGeneration == generation else {
            throw ServiceFailure.overloaded
        }
        changing.insert(id)
        defer { finishChange(id) }
        if let runtime = runtimes[id] {
            await runtime.stop()
            runtimes[id] = nil
        }
        // A failed durable intent write may stop the provider, but cannot erase
        // recovery data or publish permission to sign in.
        try registry.save(record)
        try await providers.forgetCredentials(for: record)
        try storage.erase(id)
        record.authenticationState = "required"
        try registry.save(record)
        records[id] = record
        accountStateChanged()
    }

    func retryAuthenticationRecovery(_ record: AccountRecord) async throws -> AccountSummary {
        switch record.authenticationState {
        case nil:
            try await restartRuntime(record)
        case "erasing":
            scheduleAuthenticationRecovery(record)
            await maintenance[record.id]?.value
        case "required": break
        default: throw ServiceFailure.unsupportedOperation
        }
        guard let current = records[record.id] else { throw ServiceFailure.accountNotFound }
        guard current.authenticationState != "erasing" else { throw ServiceFailure.accountCleanupPending }
        return AccountSummary(
            id: current.id,
            selfID: current.selfID,
            label: current.label,
            connection: .disconnected(reason: nil, issue: nil),
            isEnabled: current.isEnabled,
            revision: current.currentRevision,
            authenticationState: current.authenticationState
        )
    }

    private func restartRuntime(_ record: AccountRecord) async throws {
        guard !changing.contains(record.id), !shuttingDown else { throw ServiceFailure.overloaded }
        guard record.isEnabled else { return }
        changing.insert(record.id)
        defer { finishChange(record.id) }
        await runtimes[record.id]?.stop()
        runtimes[record.id] = nil
        guard !shuttingDown else { return }
        let runtime = try makeRuntime(record)
        runtimes[record.id] = runtime
        await runtime.start()
    }
}
