import ChatAPI
import ChatKit
import DesignSystem
import Foundation
import ServiceClient
import Testing
@testable import AppCore

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWorkspaceTests {
    @Test func switchingChangesViewingWithoutStoppingEitherAccount() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.setViewing(active: true, windowOpen: true, minimized: false)
        workspace.start()
        try await workspaceEventually {
            workspace.environment(for: first.id) != nil && workspace.environment(for: second.id) != nil
        }
        let firstEnvironment = try #require(workspace.environment(for: first.id))
        let secondEnvironment = try #require(workspace.environment(for: second.id))
        #expect(host.prepared)
        #expect(firstEnvironment.isViewing)
        #expect(!secondEnvironment.isViewing)
        workspace.select(second.id)
        #expect(!firstEnvironment.isViewing)
        #expect(secondEnvironment.isViewing)
        workspace.setViewing(active: true, windowOpen: false, minimized: false)
        #expect(!firstEnvironment.isViewing && !secondEnvironment.isViewing)
        #expect(host.creations[first.id] == 1 && host.creations[second.id] == 1)
        #expect(host.services[first.id]?.backend.disconnectCount == 0)
        #expect(host.services[second.id]?.backend.disconnectCount == 0)
        await workspace.stop()
    }

    @Test func disablingReleasesOneClientAndRetainsItsCachedHistory() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { host.services[first.id] != nil && host.services[second.id] != nil }
        let paused = try #require(host.services[second.id])
        await transport.publish([first, workspaceAccount("second", enabled: false, ready: false)])
        try await workspaceEventually { paused.backend.disconnectCount == 1 }
        #expect(workspace.environment(for: second.id) == nil)
        #expect(try paused.store.conversations().first?.title == "second")
        #expect(host.services[first.id]?.backend.disconnectCount == 0)
        await transport.publish([first, second])
        try await workspaceEventually {
            host.creations[second.id] == 2 && workspace.environment(for: second.id) != nil
        }
        #expect(try host.services[second.id]?.store.conversations().first?.title == "second")
        await workspace.stop()
    }

    @Test func unexpectedRuntimeRetirementShowsARetryableErrorInsteadOfConnectingForever() async throws {
        let first = workspaceAccount("first", runtimeID: UUID())
        let transport = WorkspaceTransport([first])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.environment(for: first.id) != nil }
        await transport.publish([workspaceAccount("first", ready: false)])
        try await workspaceEventually { workspace.accountErrors[first.id] != nil }
        #expect(workspace.environment(for: first.id) == nil)
        #expect(workspace.accountErrors[first.id] == "This account stopped syncing. Try again.")
        await transport.publish([workspaceAccount("first", runtimeID: UUID())])
        try await workspaceEventually {
            workspace.environment(for: first.id) != nil && workspace.accountErrors[first.id] == nil
        }
        await workspace.stop()
    }

    @Test func aCoalescedRuntimeReplacementDetachesTheOldClientWithoutErasingHistory() async throws {
        let first = workspaceAccount("first", runtimeID: UUID())
        let transport = WorkspaceTransport([first])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.environment(for: first.id) != nil }
        let previous = try #require(host.services[first.id])
        let environment = try #require(workspace.environment(for: first.id))
        let replacement = workspaceAccount("first", runtimeID: UUID())
        // Complete snapshots can omit the intermediate disabled/not-ready states.
        await transport.publish([replacement])
        try await workspaceEventually {
            host.creations[first.id] == 2 && workspace.environment(for: first.id) != nil
        }
        #expect(workspace.environment(for: first.id) !== environment)
        #expect(previous.backend.disconnectCount == 1)
        #expect(try previous.store.conversations().first?.title == "first")
        #expect(!host.erased.contains(first.id))
        #expect(workspace.sessions[first.id]?.account.runtimeID == replacement.runtimeID)
        await workspace.stop()
    }

    @Test func draftsWithTheSameAddressStayWithTheirAccountAndEraseOnDetach() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually {
            workspace.environment(for: first.id) != nil && workspace.environment(for: second.id) != nil
        }
        let firstEnvironment = try #require(workspace.environment(for: first.id))
        let secondEnvironment = try #require(workspace.environment(for: second.id))
        let address = ComposerDraftAddress(conversation: Conversation.ID("same"))
        var draft = ComposerDraft()
        draft.edit("Draft for first")
        firstEnvironment.actions.preserveDraft?(address, draft)
        workspace.select(second.id)
        #expect(secondEnvironment.sceneState.composerDrafts[address] == nil)
        draft.edit("Draft for second")
        secondEnvironment.actions.preserveDraft?(address, draft)
        workspace.select(first.id)
        #expect(firstEnvironment.sceneState.composerDrafts[address]?.text == "Draft for first")
        #expect(secondEnvironment.sceneState.composerDrafts[address]?.text == "Draft for second")
        let retiredCallback = firstEnvironment.actions.preserveDraft
        await workspace.stop()
        retiredCallback?(address, draft)
        #expect(firstEnvironment.composerDrafts.isEmpty)
        #expect(secondEnvironment.composerDrafts.isEmpty)
    }

    @Test func fatalAuthenticationErasesOnlyItsClientReplicaBeforeSignIn() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually {
            workspace.environment(for: first.id) != nil && workspace.environment(for: second.id) != nil
        }
        let expired = try #require(host.services[first.id])
        await transport.publish([workspaceAccount("first", authentication: "required", ready: false), second])
        try await workspaceEventually { workspace.cleanedBindings[first.id] == first.revision }
        #expect(workspace.environment(for: first.id) == nil)
        #expect(try expired.store.conversations().isEmpty)
        #expect(expired.backend.disconnectCount == 1)
        #expect(host.services[second.id]?.backend.disconnectCount == 0)
        try await workspace.beginLink(replacing: first.id)
        #expect(workspace.capture?.accountID == first.id)
        await workspace.stop()
    }

    @Test func aRefusedClientEraseBlocksCaptureAndCanBeRetried() async throws {
        let expired = workspaceAccount("first", authentication: "required", ready: false)
        let transport = WorkspaceTransport([expired])
        let host = WorkspaceHost()
        host.eraseFailure = true
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.accountErrors[expired.id] != nil }
        await #expect(throws: ServiceFailure.accountCleanupPending) {
            try await workspace.beginLink(replacing: expired.id)
        }
        #expect(await transport.beginnings == 0)
        host.eraseFailure = false
        await workspace.retry(expired.id)
        try await workspaceEventually { workspace.cleanupRecords.isEmpty && host.erased.contains(expired.id) }
        try await workspace.beginLink(replacing: expired.id)
        #expect(await transport.beginnings == 1)
        await workspace.stop()
    }

    @Test func aHeldAccountStartupCannotBlockAnotherAccountOrInstallAfterDisable() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second])
        let host = WorkspaceHost()
        host.hold = first.id
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually {
            host.entered.contains(first.id) && workspace.environment(for: second.id) != nil
        }
        await transport.publish([workspaceAccount("first", enabled: false, ready: false), second])
        try await workspaceEventually { workspace.accounts.first?.isEnabled == false }
        host.release(first.id)
        try await workspaceEventually { workspace.jobs[first.id] == nil }
        #expect(workspace.environment(for: first.id) == nil)
        #expect(workspace.environment(for: second.id) != nil)
        #expect(host.services[first.id]?.backend.connectEntered == false)
        #expect(host.services[second.id]?.backend.disconnectCount == 0)
        await workspace.stop()
    }

    @Test func removedAccountsReleaseTheirClientLifecycleBookkeeping() async throws {
        let first = workspaceAccount("first")
        let transport = WorkspaceTransport([first])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.environment(for: first.id) != nil }
        let previous = try #require(host.services[first.id])
        await transport.publish([])
        try await workspaceEventually { workspace.accounts.isEmpty && workspace.jobs.isEmpty }
        #expect(previous.backend.disconnectCount == 1)
        #expect(try previous.store.conversations().isEmpty)
        #expect(workspace.sessions.isEmpty && workspace.cleanupSessions.isEmpty)
        #expect(workspace.cleanedBindings.isEmpty && workspace.generations.isEmpty)
        #expect(workspace.intents.isEmpty && workspace.accountErrors.isEmpty)
        await workspace.stop()
    }

    @Test func replacementBindingsDrainAndEraseThePreviousClientBeforeOpening() async throws {
        let first = workspaceAccount("first")
        let transport = WorkspaceTransport([first])
        let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.environment(for: first.id) != nil }
        let previous = try #require(host.services[first.id])
        await transport.publish([workspaceAccount("first", revision: "replacement")])
        try await workspaceEventually {
            host.creations[first.id] == 2 && workspace.environment(for: first.id) != nil
        }
        #expect(previous.backend.disconnectCount == 1)
        #expect(try previous.store.conversations().isEmpty)
        #expect(workspace.sessions[first.id]?.account.revision == ServiceAccountRevision("replacement"))
        await workspace.stop()
    }
}
