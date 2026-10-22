import ChatAPI
import ChatService
import ChatServiceStorage
import Foundation
import LocalBridgeBackend

extension LaunchProbes {
    static func synchronizationProbe() async -> String {
        await accountProbe(named: "sync-probe.txt", title: "Kibble recovery probe") { store, account in
            await ProviderRecoveryProbeReport.run(store: store, expectedSelfID: account.selfID)
        }
    }

    /// `--probe=preview`: unjoined spaces' history and other people's Do not
    /// disturb end, read for every enabled account (`PreviewProbeReport`).
    static func previewProbe() async -> String {
        await accountProbe(named: "preview-probe.txt", title: "Kibble preview probe") { store, account in
            await PreviewProbeReport.run(store: store, expectedSelfID: account.selfID)
        }
    }

    /// Runs `probe` with each enabled account's committed credentials, read
    /// from the registry without migrating or recovering it.
    private static func accountProbe(
        named name: String,
        title: String,
        _ probe: (KeychainCredentialStore, AccountRecord) async -> String
    ) async -> String {
        do {
            let directory = try SystemLaunchServices.supportDirectory().appendingPathComponent("Accounts")
            let info = try ServiceCodec.decode(ServiceInfo.self, from: Data(
                contentsOf: directory.appendingPathComponent("instance.json")
            ))
            let accounts = try SQLiteAccountRegistry.readExistingAccounts(
                path: directory.appendingPathComponent("registry.sqlite").path
            ).filter { $0.isEnabled && !$0.isRemoving && $0.authenticationState == nil }
            let custody = try LocalAccountCustody(
                storage: KeychainSecretStorage(service: KeychainCredentialStore.defaultService),
                instanceID: info.instanceID
            )
            var lines = ["\(title); enabled accounts=\(accounts.count)"]
            for (index, account) in accounts.enumerated() {
                lines.append("account index \(index):")
                let store = try await custody.credentialStore(for: account)
                await lines.append(probe(store, account))
            }
            let report = lines.joined(separator: "\n")
            _ = write(report, to: name)
            return report
        } catch {
            let failure = error as NSError
            let report = "\(title) could not read account context: "
                + "\(failure.domain) code=\(failure.code)."
            _ = write(report, to: name)
            return report
        }
    }
}
