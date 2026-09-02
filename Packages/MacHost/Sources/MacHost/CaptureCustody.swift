import Foundation
import LocalBridgeBackend

/// Where a capture goes, and what is already stored.
///
/// Exists because the Keychain cannot be faked from here.
/// `KeychainCredentialStore`'s injectable initialiser and the `SecretStorage`
/// it takes are both internal to `LocalBridgeBackend`, and
/// `CookieCapture.save(to:)` wants the concrete store - so a model that names
/// it directly can only be tested against the real Keychain, which would mean
/// a test suite that overwrites the person's live session. Two methods, so the
/// model can be driven through every outcome with nothing at stake.
public protocol CaptureCustody: Sendable {
    /// Stores the capture's session. `false` when nothing in the capture
    /// belongs to Chat - which is not an error, just a capture taken too
    /// early.
    func save(_ capture: CookieCapture) async throws -> Bool

    /// A sentence describing what is stored, or `nil` when nothing is. Names
    /// no cookie and carries no value.
    func storedDescription() async throws -> String?
}

/// The real thing, and the only conformance that touches the Keychain.
public struct KeychainCaptureCustody: CaptureCustody {
    private let store: KeychainCredentialStore

    public init(store: KeychainCredentialStore = KeychainCredentialStore()) {
        self.store = store
    }

    public func save(_ capture: CookieCapture) async throws -> Bool {
        try await capture.save(to: store)
    }

    public func storedDescription() async throws -> String? {
        try await store.summary(at: Date())?.description
    }
}
