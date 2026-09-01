import Foundation
import GChatBridgeCore
import Security

/// What a Keychain refusal actually means, in a sentence.
///
/// Third instance of a pattern this repo keeps needing. `ShellDiagnosis` exists
/// because a 200 that is not a shell looks like bad credentials; `LoginTrace`
/// exists because a dropped popup looks like a dead button. A `SecItem` failure
/// looks like "you are not signed in", and the recoveries are nothing alike:
/// one is a login, one is a code-signing fix, one is waiting for the machine to
/// be unlocked.
public enum KeychainDiagnosis {
    /// The failure that a development build will hit first.
    ///
    /// A sandboxed app needs an application-identifier to derive its Keychain
    /// access group from, and a self-signed certificate does not supply one -
    /// so every `SecItem` call comes back `-34018` and the app looks like it
    /// simply forgot the session.
    public static let missingEntitlement: OSStatus = -34018

    public static func explain(status: OSStatus) -> String {
        switch status {
        case missingEntitlement:
            """
            the Keychain refused this app (errSecMissingEntitlement, -34018). \
            This is a code-signing problem, not a credentials one: a sandboxed \
            app needs a signing identity that grants it a Keychain access \
            group. Check GCHAT_SIGN_IDENTITY and the app's entitlements.
            """
        case errSecInteractionNotAllowed:
            "the Keychain is locked and cannot be read without interaction (-25308)."
        case errSecUserCanceled:
            "the Keychain prompt was cancelled, so the session was not read."
        case errSecAuthFailed:
            "the Keychain refused authentication (-25293)."
        default:
            "the Keychain returned status \(status)."
        }
    }

    /// The same, for the error the credential store actually throws.
    public static func explain(_ error: any Error) -> String {
        switch error {
        case CredentialStoreError.unreadable:
            """
            the stored session could not be decoded, so it cannot be used. \
            Sign in again to replace it.
            """
        case let CredentialStoreError.unavailable(status):
            explain(status: OSStatus(status))
        default:
            String(describing: error)
        }
    }
}
