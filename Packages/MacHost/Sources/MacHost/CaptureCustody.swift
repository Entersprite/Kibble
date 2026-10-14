import Foundation
import LocalBridgeBackend

/// Where a capture goes, and what is already stored.
///
/// Exists because the Keychain cannot be faked from here.
/// `KeychainCredentialStore`'s injectable initialiser and the `SecretStorage`
/// it takes are both internal to `LocalBridgeBackend`, and
/// `CookieCapture.save(to:)` wants the concrete store - so a model that names
/// it directly can only be tested against the real Keychain, which would mean
/// a test suite that overwrites the person's live session. A small protocol, so the
/// model can be driven through every outcome with nothing at stake.
public protocol CaptureCustody: Sendable {
    /// Stores the capture's session. `false` when nothing in the capture
    /// belongs to Chat - which is not an error, just a capture taken too
    /// early.
    func save(_ capture: CookieCapture) async throws -> Bool

    /// A sentence describing what is stored, or `nil` when nothing is. Names
    /// no cookie and carries no value.
    func storedDescription() async throws -> String?
    /// Account-verifies fresh browser cookies, then merges only call-host cookies.
    func saveCallCookies(_ cookies: [CapturedCookie], belongingTo capture: CookieCapture) async throws -> Int
}

public extension CaptureCustody {
    func saveCallCookies(_: [CapturedCookie], belongingTo _: CookieCapture) async throws -> Int {
        0
    }
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

    public func saveCallCookies(
        _ cookies: [CapturedCookie],
        belongingTo capture: CookieCapture
    ) async throws -> Int {
        try await MeetWebCredentials.save(
            captured: cookies, to: store, expectedCapture: capture, validatesCallSignIn: true
        )
    }
}
