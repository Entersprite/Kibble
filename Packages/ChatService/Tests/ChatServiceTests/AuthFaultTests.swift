import ChatAPI
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AuthFaultTests {
    private final class RefusedErase: ServiceStorageFactory, @unchecked Sendable {
        let backing: SQLiteServiceStorageFactory
        let account: ConnectedAccountID
        private let lock = NSLock()
        private var refuses = true
        init(backing: SQLiteServiceStorageFactory, account: ConnectedAccountID) {
            self.backing = backing
            self.account = account
        }

        func open(_ account: ConnectedAccountID) throws -> any ServiceAccountStorage {
            try backing
                .open(account)
        }

        func erase(_ account: ConnectedAccountID) throws {
            let refused = lock.withLock {
                if account == self.account, refuses {
                    refuses = false; return true
                }
                return false
            }
            if refused {
                throw ServiceFailure.internalFailure
            }
            try backing.erase(account)
        }
    }

    private final class RefusedPhaseSave: AccountLinkRegistry, @unchecked Sendable {
        let backing: SQLiteAccountRegistry
        private let lock = NSLock()
        private var remaining: Int
        private let phase: String
        init(backing: SQLiteAccountRegistry, phase: String = "required", failures: Int = 1) {
            self.backing = backing
            self.phase = phase
            remaining = failures
        }

        func accounts() throws -> [AccountRecord] {
            try backing.accounts()
        }

        func save(_ account: AccountRecord) throws {
            let refused = lock.withLock {
                if account.authenticationState == phase, remaining > 0 {
                    remaining -= 1
                    return true
                }
                return false
            }
            if refused {
                throw ServiceFailure.internalFailure
            }
            try backing.save(account)
        }

        func remove(_ account: ConnectedAccountID) throws {
            try backing.remove(account)
        }

        func links() throws -> [AccountLinkRecord] {
            try backing.links()
        }

        func saveLink(_ link: AccountLinkRecord) throws {
            try backing.saveLink(link)
        }

        func commitLink(_ link: AccountLinkRecord, account: AccountRecord) throws {
            try backing.commitLink(
                link,
                account: account
            )
        }
    }

    @Test func aStorageFaultStopsItsRuntimeWithoutErasingOrRebindingTheAccount() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        let runtime = try #require(await harness.service.runtimes[harness.first.id])
        await harness.service.runtimeFailed(
            harness.first.id,
            generation: harness.first.credentialGeneration,
            instanceID: runtime.instanceID,
            fault: .storage
        )
        try await authEventually {
            let stopped = await harness.service.runtimes[harness.first.id] == nil
            let finished = await harness.service.maintenance.isEmpty
            return stopped && finished
        }
        #expect(try harness.state(harness.first.id) == nil)
        #expect(await harness.providers.forgotten.isEmpty)
        #expect(try harness.storage.open(harness.first.id).conversations().count == 1)
        let request = try ServiceRequest(
            header: ServiceRequestHeader(
                requestID: ServiceRequestID("stream"),
                accountID: harness.first.id,
                accountRevision: harness.first
                    .currentRevision
            ),
            payload: ReadEvents(cursor: nil, limit: 1)
        )
        await #expect(throws: ServiceFailure.overloaded) {
            try await harness.service.events(ServiceCodec.encode(request), context: harness.context)
        }
        _ = try await harness.call(RetryAccountRecovery(), account: harness.first.id)
        try await harness.ready(harness.first.id)
        #expect(await harness.service.activeRuntimeCount == 2)
        await harness.service.shutdown()
    }

    @Test func refusedIntentCommitStopsTheProviderButCannotEraseOrPublishSignIn() async throws {
        let initial = try await AuthHarness.make()
        let refusal = RefusedPhaseSave(backing: initial.registry, phase: "erasing", failures: 2)
        let harness = try await initial.restarted(providers: AuthProviders(), registryOverride: refusal)
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually {
            let state = await harness.service.records[harness.second.id]?.authenticationState
            let finished = await harness.service.maintenance.isEmpty
            return state == "erasing" && finished
        }
        #expect(try harness.state(harness.second.id) == nil)
        #expect(await harness.providers.forgetAttempts == 0)
        #expect(await harness.service.activeRuntimeCount == 1)
        #expect(try harness.storage.open(harness.second.id).conversations().count == 1)
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.second.id
            ))
        }
        _ = try await harness.call(RetryAccountRecovery(), account: harness.second.id)
        #expect(try harness.state(harness.second.id) == "required")
        await harness.service.shutdown()
    }

    @Test func refusedCacheErasureKeepsSignInBlockedEvenAfterCredentialsAreGone() async throws {
        let initial = try await AuthHarness.make()
        let refusal = RefusedErase(backing: initial.storage, account: initial.second.id)
        let harness = try await initial.restarted(providers: AuthProviders(), storageOverride: refusal)
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually {
            let finished = await harness.service.maintenance.isEmpty
            return try harness.state(harness.second.id) == "erasing" && finished
        }
        #expect(await harness.providers.forgotten == [harness.second.id])
        #expect(try harness.storage.open(harness.second.id).conversations().count == 1)
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.second.id
            ))
        }
        _ = try await harness.call(RetryAccountRecovery(), account: harness.second.id)
        #expect(try harness.state(harness.second.id) == "required")
        #expect(try harness.storage.open(harness.second.id).conversations().isEmpty)
        await harness.service.shutdown()
    }

    @Test func refusedCompletionCommitCannotPublishSignInBeforeDurableRecoveryFinishes() async throws {
        let initial = try await AuthHarness.make()
        let refusal = RefusedPhaseSave(backing: initial.registry)
        let harness = try await initial.restarted(providers: AuthProviders(), registryOverride: refusal)
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually {
            let finished = await harness.service.maintenance.isEmpty
            return try harness.state(harness.second.id) == "erasing" && finished
        }
        #expect(try harness.storage.open(harness.second.id).conversations().isEmpty)
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.second.id
            ))
        }
        let response = try await harness.call(RetryAccountRecovery(), account: harness.second.id)
        #expect(response.authenticationState == "required")
        #expect(try harness.state(harness.second.id) == "required")
        #expect(await harness.providers.forgetAttempts == 2)
        await harness.service.shutdown()
    }
}
