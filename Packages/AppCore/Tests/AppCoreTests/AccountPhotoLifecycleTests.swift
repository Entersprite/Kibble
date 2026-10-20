import ChatAPI
import ChatKit
import DesignSystem
import Foundation
import ServiceClient
import Testing
@testable import AppCore

@MainActor
struct AccountPhotoLifecycleTests {
    @Test func aDisabledAccountRestoresItsPhotoWithoutCreatingAProviderAndRemovalRevokesItsLoader(
    ) async throws {
        let account = workspaceAccount("first", enabled: false, ready: false)
        let url = try #require(URL(string: "https://example.invalid/avatar"))
        let candidate = AccountProfilePhoto(url: url, data: Data([1, 2, 3]))
        let photo = try #require(candidate)
        let host = WorkspaceHost(); host.cachedPhotos[account.id] = photo
        let transport = WorkspaceTransport([account])
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { !workspace.isLoading }
        let row = try #require(workspace.accountPanelState(scene: nil).accounts.first)
        let loader = try #require(row.imageLoader)
        #expect(try await loader.load(url) == photo.data)
        #expect(host.creations.isEmpty)
        await transport.publish([])
        try await workspaceEventually { workspace.accounts.isEmpty }
        await #expect(throws: (any Error).self) { try await loader.load(url) }
        await workspace.stop()
    }

    @Test func runningAccountRemovalAlsoDrainsHostOwnedDisplayCleanup() async throws {
        let first = workspaceAccount("first"), second = workspaceAccount("second")
        let transport = WorkspaceTransport([first, second]); let host = WorkspaceHost()
        let workspace = AccountWorkspace(client: AccountClient(transport: transport), host: host)
        workspace.start()
        try await workspaceEventually { workspace.environment(for: first.id) != nil }
        await transport.publish([second])
        try await workspaceEventually { host.erased.contains(first.id) }
        #expect(workspace.environment(for: first.id) == nil)
        await workspace.stop()
    }
}
