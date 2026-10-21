import ChatAPI
import ChatServiceStorage
import Foundation
import LocalBridgeBackend

extension LaunchProbes {
    static func synchronizationProbe() async -> String {
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
            var lines = ["Kibble recovery probe; enabled accounts=\(accounts.count)"]
            for (index, account) in accounts.enumerated() {
                lines.append("account index \(index):")
                let store = try await custody.credentialStore(for: account)
                await lines.append(ProviderRecoveryProbeReport.run(
                    store: store,
                    expectedSelfID: account.selfID
                ))
            }
            let report = lines.joined(separator: "\n")
            _ = write(report, to: "sync-probe.txt")
            return report
        } catch {
            let failure = error as NSError
            let report = "Recovery probe could not read account context: "
                + "\(failure.domain) code=\(failure.code)."
            _ = write(report, to: "sync-probe.txt")
            return report
        }
    }
}
