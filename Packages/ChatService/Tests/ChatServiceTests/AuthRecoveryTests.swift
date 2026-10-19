import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AuthRecoveryTests {
    @Test func signInStaysBlockedUntilCredentialCleanupHasActuallyFinished() async throws {
        let providers = AuthProviders()
        await providers.configure(holdForget: true)
        let harness = try await AuthHarness.make(providers: providers)
        defer { Task { await providers.releaseForget() } }
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually { await providers.forgetAttempts == 1 }
        #expect(try harness.state(harness.second.id) == "erasing")
        #expect(await harness.service.activeRuntimeCount == 1)
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.second.id
            ))
        }
        #expect(try await harness.call(LoadConversations(), account: harness.first.id).count == 1)
        await providers.releaseForget()
        try await authEventually { try harness.state(harness.second.id) == "required" }
        await harness.service.shutdown()
    }

    @Test func failedCredentialCleanupResumesOnRestartWithoutConstructingAProviderForThatAccount(
    ) async throws {
        let providers = AuthProviders()
        await providers.configure(forgetFailures: 1)
        let harness = try await AuthHarness.make(providers: providers)
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually {
            let finished = await harness.service.maintenance.isEmpty
            return try harness.state(harness.second.id) == "erasing" && finished
        }
        #expect(try harness.storage.open(harness.second.id).conversations().count == 1)
        let restarted = try await harness.restarted(providers: AuthProviders())
        try await authEventually { try restarted.state(restarted.second.id) == "required" }
        #expect(await restarted.providers.attempts[restarted.second.id] == nil)
        await restarted.custody.configure(identity: restarted.second.selfID)
        let link = try await restarted.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: restarted.second.id
        ))
        _ = try await restarted.call(CompleteAccountLink(linkID: link.id))
        try await restarted.ready(restarted.second.id)
        #expect(try restarted.state(restarted.second.id) == nil)
        #expect(await restarted.service.activeRuntimeCount == 2)
        #expect(try restarted.registry.accounts().first { $0.id == restarted.second.id }?
            .currentRevision != restarted.second.currentRevision)
        await restarted.service.shutdown()
    }

    @Test func failedCleanupCanBeRetriedWithoutStartingAProviderOrLosingTheAccount() async throws {
        let providers = AuthProviders()
        await providers.configure(forgetFailures: 1)
        let harness = try await AuthHarness.make(providers: providers)
        try await harness.ready(harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.notAuthenticated))
        try await authEventually {
            let finished = await harness.service.maintenance.isEmpty
            return try harness.state(harness.second.id) == "erasing" && finished
        }
        let recovered = try await harness.call(RetryAccountRecovery(), account: harness.second.id)
        #expect(recovered.authenticationState == "required")
        #expect(await providers.forgetAttempts == 2)
        #expect(await providers.attempts[harness.second.id] == 1)
        #expect(try harness.registry.accounts().count == 2)
        await harness.service.shutdown()
    }

    @Test func aRefusedCredentialReadCanBeRetriedWithoutErasingOrPromptingForSignIn() async throws {
        let providers = AuthProviders()
        let identity = LinkHarness.existing().selfID
        await providers.configure(identity: identity, failure: .unknown("Synthetic custody refusal"))
        let harness = try await AuthHarness.make(providers: providers)
        try await authEventually {
            let accounts = try await harness.call(ListAccounts())
            return accounts.first { $0.id == harness.first.id }?.connection == .disconnected(
                reason: nil,
                issue: nil
            )
        }
        #expect(try harness.state(harness.first.id) == nil)
        #expect(await providers.forgotten.isEmpty)
        await providers.configure(identity: identity, failure: nil)
        _ = try await harness.call(RetryAccountRecovery(), account: harness.first.id)
        try await harness.ready(harness.first.id)
        #expect(await providers.attempts[harness.first.id] == 2)
        #expect(await providers.forgotten.isEmpty)
        await harness.service.shutdown()
    }

    @Test func aConnectThatFinishesAfterDisableCannotReopenItsProvider() async throws {
        let providers = AuthProviders()
        await providers.configure(holdConnect: true)
        let harness = try await AuthHarness.make(providers: providers)
        let first = try await harness.backend(harness.first.id)
        let second = try await harness.backend(harness.second.id)
        defer { Task { await first.releaseConnect(); await second.releaseConnect() } }
        await second.releaseConnect()
        try await harness.ready(harness.second.id)
        let disabling = Task { try await harness.call(
            SetAccountEnabled(enabled: false),
            account: harness.first.id
        ) }
        try await authEventually { await first.disconnects > 0 }
        await first.releaseConnect()
        let disabled = try await disabling.value
        #expect(!disabled.isEnabled)
        #expect(await first.connected == false)
        #expect(await first.disconnects >= 2)
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test(arguments: [false, true])
    func staleRuntimeIncidentsCannotEraseAReplacementRuntime(changesCredential: Bool) async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        let oldRuntime = try #require(await harness.service.runtimes[harness.first.id])
        if changesCredential {
            await harness.custody.configure(identity: harness.first.selfID)
            let link = try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.first.id
            ))
            _ = try await harness.call(CompleteAccountLink(linkID: link.id))
        } else {
            _ = try await harness.call(RetryAccountRecovery(), account: harness.first.id)
        }
        try await harness.ready(harness.first.id)
        let current = try #require(harness.registry.accounts().first { $0.id == harness.first.id })
        let runtime = try #require(await harness.service.runtimes[current.id])
        let staleInstance = changesCredential ? runtime.instanceID : oldRuntime.instanceID
        await harness.service.runtimeFailed(
            current.id,
            generation: harness.first.credentialGeneration,
            instanceID: staleInstance,
            fault: .authentication
        )
        #expect(try harness.state(current.id) == nil)
        #expect(await harness.providers.forgotten.isEmpty)
        await harness.service.runtimeFailed(
            current.id,
            generation: current.credentialGeneration,
            instanceID: runtime.instanceID,
            fault: .authentication
        )
        try await authEventually { try harness.state(current.id) == "required" }
        #expect(await harness.providers.forgotten == [current.id])
        await harness.service.shutdown()
    }
}
