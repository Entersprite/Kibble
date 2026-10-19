import AppCore
import ChatAPI
import ChatKit
import FixtureBackend
import Foundation
import ServiceClient
import SyncEngine

@MainActor
final class FixtureAccountLaunchServices: LaunchServices {
    let arguments = LaunchArguments(backend: .fixture)
    let launchReportRequested = false
    let diagnosticsRequested = false
    private let account: AccountSummary
    private let client: AccountClient
    private let directory: URL
    private let downloads: any DownloadPlatform
    private let transport: any ServiceEventTransport

    init(
        account: AccountSummary,
        client: AccountClient,
        directory: URL,
        downloads: any DownloadPlatform,
        transport: any ServiceEventTransport
    ) {
        self.account = account; self.client = client; self.directory = directory; self
            .downloads = downloads; self.transport = transport
    }

    func hasStoredSession() -> Bool {
        true
    }

    func forgetStoredSession() async throws {
        try await client.remove(account.id)
    }

    func openStore() throws -> ChatStore {
        try ChatStore
            .onDisk(at: directory.appendingPathComponent("replica.sqlite").path)
    }

    func eraseStore() throws {
        try openStore().erase(); try eraseBackendCaches()
    }

    func eraseBackendCaches() throws {
        for url in [attachmentCacheDirectory(), directory.appendingPathComponent("binding.json")]
            .compactMap(\.self) {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { continue }
        }
    }

    func makeSession() throws -> SessionSelection {
        let now = FixtureWorld.acme.startedAt
        return SessionSelection(
            backend: ServiceBackend(account: account, transport: transport), me: account.selfID, now: { now }
        )
    }

    func runLaunchReport() -> String {
        "No account report was requested."
    }

    func startDiagnostics() {}
    func markReadTraceSink() -> (any MarkReadTraceSink)? {
        nil
    }

    func attachmentCacheDirectory() -> URL? {
        directory.appendingPathComponent(
            "attachments",
            isDirectory: true
        )
    }

    func downloadPlatform() -> any DownloadPlatform {
        downloads
    }

    func chooseFilesToSend() -> [URL] {
        SystemFilePicker.chooseFilesToSend()
    }
}
