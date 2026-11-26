import Foundation
import Security
import Testing
@testable import MacHost

/// The one part that talks to the real Keychain, checked at the level it can
/// be: the attributes it asks for.
struct KeychainQueryTests {
    /// A Google session cookie must not ride iCloud Keychain to other devices.
    ///
    /// "The session cookies never leave the Mac" is the architecture's custody
    /// claim and the difference between the E2E tier and the hosted one. A
    /// synchronisable Keychain item would quietly make it false.
    @Test func theItemIsNotSynchronisedToOtherDevices() {
        let query = KeychainSecretStorage.baseQuery(service: "s", account: "a")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// The menu-bar agent reconnects after a reboot without anyone opening a
    /// window, so the credential has to be readable once the machine has been
    /// unlocked - but never before, and never off this device.
    @Test func theItemIsReadableAfterFirstUnlockAndOnlyOnThisDevice() {
        let attributes = KeychainSecretStorage.addAttributes(
            service: "s",
            account: "a",
            data: Data("x".utf8)
        )
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        )
    }

    @Test func theQueryIsForAGenericPasswordUnderTheGivenServiceAndAccount() {
        let query = KeychainSecretStorage.baseQuery(service: "svc", account: "acct")
        #expect(query[kSecClass as String] as? String == (kSecClassGenericPassword as String))
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "acct")
    }

    /// Which keychain this is, made explicit rather than inherited from a
    /// default nobody chose.
    ///
    /// Without `kSecUseDataProtectionKeychain`, macOS uses the legacy
    /// file-based keychain, where `kSecAttrAccessible` is ignored entirely and
    /// item ACLs are bound to the accessing binary's code signature - which is
    /// what produces the "wants to use your confidential information" password
    /// dialog on a signature change. The flag is therefore a custody decision,
    /// exactly like the two beside it, and gets the same treatment: pinned.
    @Test func theQueryNamesWhichKeychainItMeans() {
        let legacy = KeychainSecretStorage.baseQuery(
            service: "s", account: "a", useDataProtection: false
        )
        #expect(legacy[kSecUseDataProtectionKeychain as String] as? Bool == false)

        let modern = KeychainSecretStorage.baseQuery(
            service: "s", account: "a", useDataProtection: true
        )
        #expect(modern[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    /// The default must not change silently. Whatever the measurement in
    /// findings.md §19.4 concludes, the value that ships is the one written
    /// here, and changing it is a deliberate edit to a test rather than a
    /// side effect of touching the query builder.
    @Test func theDefaultKeychainIsTheLegacyOneUntilTheMigrationIsMeasured() {
        let query = KeychainSecretStorage.baseQuery(service: "s", account: "a")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
    }
}
