import AppCore
import ChatAPI
import ChatKit
import FixtureBackend
import Foundation
import ServiceClient
import SyncEngine

@MainActor
final class ServiceAccountLaunchServices: LaunchServices {
    let arguments: LaunchArguments
    private let fixture: Bool
    let launchReportRequested = false
    let diagnosticsRequested = false
    private let account: AccountSummary
    private let client: AccountClient
    private let directory: URL
    private let downloads: any DownloadPlatform
    private let transport: any ServiceEventTransport
    private weak var backend: ServiceBackend?

    init(
        account: AccountSummary,
        client: AccountClient,
        directory: URL,
        downloads: any DownloadPlatform,
        transport: any ServiceEventTransport, fixture: Bool = true
    ) {
        self.fixture = fixture
        arguments = LaunchArguments(backend: fixture ? .fixture : .local)
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
        for url in [
            attachmentCacheDirectory(),
            directory.appendingPathComponent("binding.json"),
            directory.appendingPathComponent("policy.json")
        ]
        .compactMap(\.self) {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile { continue }
        }
    }

    func makeSession() throws -> SessionSelection {
        let now = fixture ? FixtureWorld.acme.startedAt : Date()
        let clock: @Sendable () -> Date = if fixture {
            { now }
        } else {
            { Date() }
        }
        let backend = ServiceBackend(account: account, transport: transport)
        self.backend = backend
        return try SessionSelection(
            backend: backend, me: account.selfID,
            connectionService: fixture ? nil : ConnectionService(name: "Google Chat", operatorName: "Google"),
            audioCalls: ServiceAudioCallService(
                account: account,
                client: AccountClient(transport: transport)
            ),
            now: clock
        )
    }

    func synchronizeReplica() async throws {
        guard let backend else { throw ServiceFailure.accountDisabled }
        // Use the normal projected query/ACK barrier, including after a warm
        // launch. A simulated live arrival must follow initial replay recovery.
        _ = try await backend.loadConversations()
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
