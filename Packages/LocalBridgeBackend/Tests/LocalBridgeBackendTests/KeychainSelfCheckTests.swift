import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The check that answers "can this build use the Keychain at all".
///
/// It exists because the answer depends on how the app was signed, not on
/// anything in this repository, and because the failure mode is a silent
/// `-34018` that reads as "no session stored". `AppNapProbe` is the precedent:
/// a diagnostic kept rather than deleted the moment it first gave a good
/// answer, because the question comes back every time the environment changes.
struct KeychainSelfCheckTests {
    private final class FakeStorage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        var failure: (any Error)?
        func read(account: String) throws -> Data? {
            if let failure {
                throw failure
            }
            return items[account]
        }

        func write(_ data: Data, account: String) throws {
            if let failure {
                throw failure
            }
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    @Test func aWorkingKeychainPasses() async {
        let store = KeychainCredentialStore(storage: FakeStorage(), account: "selfcheck")
        #expect(await store.selfCheck().hasPrefix("PASS"))
    }

    @Test func aRefusedKeychainFailsWithTheDiagnosisAttached() async {
        let storage = FakeStorage()
        storage.failure = CredentialStoreError.unavailable(status: -34018)
        let store = KeychainCredentialStore(storage: storage, account: "selfcheck")
        let result = await store.selfCheck()
        #expect(result.hasPrefix("FAIL"))
        #expect(result.contains("entitlement"))
    }

    /// The check writes a credential-shaped blob, so leaving it behind would
    /// mean a diagnostic that litters the Keychain every time it runs.
    @Test func itLeavesNothingBehind() async {
        let storage = FakeStorage()
        let store = KeychainCredentialStore(storage: storage, account: "selfcheck")
        _ = await store.selfCheck()
        #expect(storage.items.isEmpty)
    }

    /// Running the check must never be able to destroy a real session.
    @Test func theCheckAccountIsNotTheAccountTheAppUses() {
        #expect(KeychainCredentialStore.selfCheckAccount != KeychainCredentialStore.defaultAccount)
    }
}
