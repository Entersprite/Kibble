import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Turning an `OSStatus` into the sentence that saves the next hour.
///
/// The repo's pattern, third time: `ShellDiagnosis` for a 200 that is not a
/// shell, `LoginTrace` for a button that does nothing, and this for a Keychain
/// that refuses. Each exists because the raw failure is indistinguishable from
/// a different, much more common one — here, "no session stored".
struct KeychainDiagnosisTests {
    /// The one that will actually happen.
    ///
    /// A sandboxed app signed with a self-signed certificate has no
    /// application-identifier to derive a Keychain access group from, and every
    /// `SecItem` call returns `-34018`. Without a name attached that reads as
    /// "signing in did not work", and the next hour goes into cookies.
    @Test func aMissingEntitlementNamesSigningRatherThanCredentials() {
        let text = KeychainDiagnosis.explain(status: -34018)
        #expect(text.contains("entitlement"))
        #expect(text.lowercased().contains("sign"))
    }

    @Test func aLockedKeychainSaysSo() {
        #expect(KeychainDiagnosis.explain(status: -25308).lowercased().contains("locked"))
    }

    @Test func userCancellationIsNotReportedAsAFailureOfTheApp() {
        #expect(KeychainDiagnosis.explain(status: -128).lowercased().contains("cancel"))
    }

    /// An unrecognised status still has to be actionable, which means the
    /// number itself must survive into the message.
    @Test func anUnknownStatusStillCarriesItsNumber() {
        #expect(KeychainDiagnosis.explain(status: -99999).contains("-99999"))
    }

    @Test func theDiagnosisIsAttachedToTheErrorTheStoreThrows() {
        let described = KeychainDiagnosis.explain(
            CredentialStoreError.unavailable(status: -34018)
        )
        #expect(described.contains("entitlement"))
    }

    /// An unreadable blob is a different problem with a different fix, and must
    /// not be described as a signing one.
    @Test func anUnreadableCredentialIsNotDescribedAsASigningProblem() {
        let described = KeychainDiagnosis.explain(CredentialStoreError.unreadable)
        #expect(!described.contains("entitlement"))
        #expect(described.lowercased().contains("sign in again"))
    }
}
