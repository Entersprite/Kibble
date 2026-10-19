import Foundation
import LocalBridgeBackend

public extension KeychainCredentialStore {
    init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = KeychainCredentialStore.defaultAccount
    ) {
        self.init(
            storage: KeychainSecretStorage(service: service),
            legacyStorage: service == Self.defaultService && account == Self.defaultAccount
                ? KeychainSecretStorage(service: "com.entersprite.gchat.session") : nil,
            account: account
        )
    }

    /// A store aimed at the self-check account.
    static func forSelfCheck() -> KeychainCredentialStore {
        KeychainCredentialStore(account: selfCheckAccount)
    }

    /// Whether this build can use the **data-protection** keychain.
    ///
    /// Asked separately from `selfCheck()` because the answer decides a
    /// migration, and the two failure modes are opposite: the legacy keychain
    /// works today and can prompt for a password; the data-protection keychain
    /// never prompts but needs an access group a self-signed certificate may
    /// not supply, which returns as `-34018` (`findings.md` §19.1).
    ///
    /// Built on a concrete `KeychainSecretStorage` rather than the injected
    /// `storage`, since `SecretStorage` stays a one-keychain protocol on
    /// purpose — see `KeychainSecretStorage`'s own note on why.
    func dataProtectionSelfCheck() async -> String {
        let storage = KeychainSecretStorage(service: KeychainCredentialStore.defaultService)
        let account = Self.dataProtectionSelfCheckAccount
        let probe = Data("probe".utf8)
        do {
            try storage.write(probe, account: account, useDataProtection: true)
            let read = try storage.read(account: account, useDataProtection: true)
            try storage.delete(account: account, useDataProtection: true)
            guard read == probe else {
                return "FAIL - the data-protection keychain returned different bytes."
            }
            return "PASS - this build can also use the data-protection keychain."
        } catch {
            return "FAIL (data-protection) - \(KeychainDiagnosis.explain(error))"
        }
    }
}
