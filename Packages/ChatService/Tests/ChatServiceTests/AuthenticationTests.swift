import ChatAPI
import ChatKit
import ChatServiceStorage
import Foundation
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct AuthenticationTests {
    @Test func fatalAuthenticationErasesOnlyTheAffectedAccountAndRetainsItsPolicy() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        try await harness.ready(harness.second.id)
        let before = try await harness.call(ReadEvents(cursor: nil, limit: 1), account: harness.second.id)
        let policy = try await harness.call(GetAccountPolicy(), account: harness.second.id)
        let saved = try await harness.call(
            SetAccountPolicy(settings: NotificationSettings(), expectedRevision: policy.revision),
            account: harness.second.id
        )
        let operation = ServiceOperationID("private-operation")
        _ = try await harness.call(SendCommand(operationID: operation, command: .sendMessage(
            conversationID: Conversation.ID("private"), threadID: nil, text: "Synthetic private message",
            localID: "one"
        )), account: harness.second.id)
        let backend = try await harness.backend(harness.second.id)
        await backend.fail(.backendError(.sessionExpired))
        try await authEventually { try harness.state(harness.second.id) == "required" }
        #expect(await harness.providers.forgotten == [harness.second.id])
        #expect(await harness.service.activeRuntimeCount == 1)
        #expect(try await harness.call(LoadConversations(), account: harness.first.id).count == 1)
        let cleared = try harness.storage.open(harness.second.id)
        #expect(try cleared.conversations().isEmpty)
        #expect(try cleared.operation(operation) == nil)
        #expect(try cleared.readEvents(after: nil, limit: 1).checkpoint.streamID != before.checkpoint
            .streamID)
        #expect(try await harness.call(GetAccountPolicy(), account: harness.second.id) == saved)
        await #expect(throws: ServiceFailure.authenticationRequired) { try await harness.call(
            ReadEvents(cursor: nil, limit: 1),
            account: harness.second.id
        ) }
        let enabled = try await harness.call(SetAccountEnabled(enabled: true), account: harness.second.id)
        #expect(enabled.authenticationState == "required")
        #expect(enabled.isEnabled)
        #expect(await harness.providers.attempts[harness.second.id] == 1)
        await harness.service.shutdown()
    }

    @Test func startupAuthFailureDoesNotDeadlockItsOwnTeardownOrStopAnotherAccount() async throws {
        let providers = AuthProviders()
        await providers.configure(identity: Member.ID("second-self"), failure: .notAuthenticated)
        let harness = try await AuthHarness.make(providers: providers)
        try await authEventually { try harness.state(harness.second.id) == "required" }
        try await harness.ready(harness.first.id)
        #expect(await harness.service.activeRuntimeCount == 1)
        #expect(await providers.forgotten == [harness.second.id])
        await harness.service.shutdown()
    }

    @Test func aTransientNotAuthenticatedQueryCannotEraseAValidLogin() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        let backend = try await harness.backend(harness.first.id)
        await backend.failQueries(.notAuthenticated)
        await #expect(throws: ServiceFailure.self) { try await harness.call(
            LoadConversations(),
            account: harness.first.id
        ) }
        #expect(try harness.state(harness.first.id) == nil)
        #expect(await harness.providers.forgotten.isEmpty)
        #expect(try harness.storage.open(harness.first.id).conversations().count == 1)
        #expect(await harness.service.activeRuntimeCount == 2)
        await harness.service.shutdown()
    }

    @Test func anExplicitExpiredQueryTriggersAccountLocalRecovery() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        let backend = try await harness.backend(harness.first.id)
        await backend.failQueries(.sessionExpired)
        await #expect(throws: ServiceFailure.accountCleanupPending) { try await harness.call(
            LoadConversations(),
            account: harness.first.id
        ) }
        try await authEventually { try harness.state(harness.first.id) == "required" }
        #expect(await harness.providers.forgotten == [harness.first.id])
        await harness.service.shutdown()
    }

    @Test func wrongProviderIdentityIsQuarantinedBeforeItCanReplaceStoredIdentity() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        let backend = try await harness.backend(harness.first.id)
        await backend.fail(.selfIdentified(Member(
            id: Member.ID("foreign"),
            kind: .human,
            displayName: "Foreign"
        )))
        try await authEventually { try harness.state(harness.first.id) == "required" }
        #expect(try harness.registry.accounts().first { $0.id == harness.first.id }?.selfID == harness.first
            .selfID)
        #expect(try harness.storage.open(harness.first.id).conversations().isEmpty)
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test func aFatalFailureDuringReconnectCommitIsNotLost() async throws {
        let harness = try await AuthHarness.make()
        try await harness.ready(harness.first.id)
        await harness.custody.configure(identity: harness.first.selfID, holdDiscard: true)
        defer { Task { await harness.custody.releaseDiscard() } }
        await harness.providers.configure(identity: harness.first.selfID, failure: .notAuthenticated)
        let link = try await harness.call(BeginAccountLink(
            operationID: ServiceOperationID("reauth"),
            targetAccountID: harness.first.id
        ))
        let completing = Task { try await harness.call(CompleteAccountLink(linkID: link.id)) }
        try await authEventually { await harness.service.deferredFaults[harness.first.id] != nil }
        #expect(try harness.state(harness.first.id) == nil)
        await harness.custody.releaseDiscard()
        _ = try await completing.value
        try await authEventually { try harness.state(harness.first.id) == "required" }
        let generation = try #require(harness.registry.accounts().first { $0.id == harness.first.id })
            .credentialGeneration
        #expect(await harness.providers.forgottenGenerations == [generation])
        #expect(await harness.providers.forgotten == [harness.first.id])
        #expect(await harness.service.activeRuntimeCount == 1)
        await harness.service.shutdown()
    }

    @Test func unknownAuthenticationStateFailsClosedWithoutErasingCredentials() async throws {
        let harness = try await AuthHarness.make(firstAuthenticationState: "futureState")
        #expect(await harness.service.activeRuntimeCount == 1)
        #expect(await harness.providers.attempts[harness.first.id] == nil)
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await harness.call(BeginAccountLink(
                operationID: ServiceOperationID("reauth"),
                targetAccountID: harness.first.id
            ))
        }
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await harness.call(RetryAccountRecovery(), account: harness.first.id)
        }
        #expect(await harness.providers.forgotten.isEmpty)
        #expect(try harness.state(harness.first.id) == "futureState")
        await harness.service.shutdown()
    }
}
