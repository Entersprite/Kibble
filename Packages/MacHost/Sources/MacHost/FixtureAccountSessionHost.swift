import AppCore
import ChatAPI
import Foundation
import ServiceClient

@MainActor
final class FixtureAccountSessionHost: AccountSessionHost {
    private let directory: URL
    private let client: AccountClient
    private let downloads: any DownloadPlatform
    private let transport: (AccountSummary) -> any ServiceEventTransport

    init(
        directory: URL,
        client: AccountClient,
        transport: @escaping (AccountSummary) -> any ServiceEventTransport
    ) {
        self.directory = directory; self.client = client; self.transport = transport
        downloads = SystemDownloadPlatform(bookmarkFile: directory.deletingLastPathComponent()
            .appendingPathComponent("downloads.bookmark"))
    }

    func prepareForAccounts(_ accounts: [AccountSummary]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let current = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for folder in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let manifest = folder.appendingPathComponent("binding.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let previous = try ServiceCodec.decode(AccountSummary.self, from: Data(contentsOf: manifest))
            let account = current[previous.id]
            if account == nil || account?.revision != previous.revision || account?.isRemoving == true ||
                ["erasing", "required"].contains(account?.authenticationState ?? "") {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    func makeEnvironment(for account: AccountSummary) async throws -> AppEnvironment {
        guard let revision = account.revision else { throw ServiceFailure.staleAccount }
        let info = try await client.serviceInfo()
        let folder = accountDirectory(account.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = folder.appendingPathComponent("binding.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let previous = try ServiceCodec.decode(AccountSummary.self, from: Data(contentsOf: manifest))
            guard previous.id == account.id,
                  previous.revision == account.revision else { throw ServiceFailure.staleAccount }
        }
        try ServiceCodec.encode(account).write(to: manifest, options: .atomic)
        let services = FixtureAccountLaunchServices(
            account: account,
            client: client,
            directory: folder,
            downloads: downloads, transport: transport(account)
        )
        let preferences = UserDefaults(suiteName: "com.entersprite.kibble.multi-account-fixture") ?? .standard
        let cache = try PolicyReplicaCache(
            binding: PolicyReplicaBinding(
                service: info.instanceID,
                account: account.id,
                revision: revision,
                identity: account.selfID
            ),
            deviceID: "fixture-device",
            storage: FilePolicyReplicaStorage(file: folder.appendingPathComponent("policy.json"))
        )
        let namespace = try ServiceCodec.encode(info.instanceID).base64EncodedString() + "."
        return AppEnvironment(
            services: services,
            settingsStore: ServiceNotificationSettingsStore(cache: cache),
            preferences: preferences,
            policyReplica: PolicyReplicaController(client: client, cache: cache),
            preferenceNamespace: namespace
        )
    }

    func eraseReplica(for account: AccountSummary) throws {
        do {
            try FileManager.default.removeItem(at: accountDirectory(account.id))
        } catch CocoaError.fileNoSuchFile { return }
    }

    private func accountDirectory(_ id: ConnectedAccountID) -> URL {
        let name = Data(id.rawValue.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(name, isDirectory: true)
    }
}
