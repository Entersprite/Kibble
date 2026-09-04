import Foundation
import GChatBridgeCore
import URLSessionTransport

/// What a host may say about the stored session without holding the credential.
///
/// Counts and dates. The credential itself stays inside this package, which is
/// what lets the app render a "signed in, expires in 9 days" line without ever
/// naming a type from `GChatBridgeCore`.
public struct StoredSessionSummary: Sendable, Hashable, CustomStringConvertible {
    public let cookieCount: Int
    public let capturedAt: Date
    public let expiresAt: Date?
    public let isExpired: Bool

    /// Whole days left, floored, or `nil` when no expiry was stated.
    public let daysRemaining: Int?

    /// A sentence for a window. Names no cookie and carries no value.
    public var description: String {
        var parts = ["\(cookieCount) cookies"]
        if isExpired {
            parts.append("expired")
        } else if let daysRemaining {
            parts.append("expires in \(daysRemaining) days")
        } else {
            parts.append("no stated expiry")
        }
        return parts.joined(separator: ", ")
    }
}

public extension KeychainCredentialStore {
    /// What is stored, described safely, or `nil` when nothing is.
    ///
    /// Takes the instant rather than reading a clock so the answer is testable
    /// and so a caller rendering several fields cannot have them disagree by a
    /// tick.
    func summary(at instant: Date) async throws -> StoredSessionSummary? {
        guard let session = try await currentSession() else { return nil }
        return StoredSessionSummary(
            cookieCount: session.credential.count,
            capturedAt: session.capturedAt,
            expiresAt: session.expiresAt,
            isExpired: session.isExpired(at: instant),
            daysRemaining: session.remainingLifetime(at: instant).map { Int($0 / 86400) }
        )
    }
}

public extension CookieCapture {
    /// Persists this capture's credential.
    ///
    /// `false` means there was nothing in scope to persist — a capture taken
    /// before Chat issued its own cookies, most likely — and the caller should
    /// say so rather than report a successful sign-in. Any previously stored
    /// session is left alone in that case, because replacing a working
    /// credential with nothing is strictly worse than keeping it.
    @discardableResult
    func save(to store: KeychainCredentialStore) async throws -> Bool {
        guard let session else { return false }
        try await store.store(session)
        return true
    }
}

public extension LocalBridgeBackend {
    /// Builds a bridge from the stored session, or `nil` when there is none.
    ///
    /// **An expired session still builds one.** Expiry is a lower bound on
    /// trouble and never a verdict — a credential can be revoked well inside
    /// every stated expiry (`findings.md` §11), and one past its expiry can
    /// still be accepted. The request that settles it costs a single round
    /// trip, and refusing to make it would promote a guess to a policy.
    ///
    /// - Parameter reachability: The device's network-reachability signal.
    /// Defaulted to a real `NWPathReachabilityMonitor` here, at the outermost
    /// public entry point, so `SystemLaunchServices.swift` — the only file
    /// allowed to name a concrete backend — stays a one-function change: it
    /// calls this overload with nothing extra and gets the accelerant for
    /// free. Pass `nil` explicitly to fall back to `ChannelSession`'s bounded
    /// timer alone, which is what every test that reaches this does by
    /// supplying its own transport and never asking for a monitor.
    /// - Parameter tracingChannelTo: A file to write the long poll's
    /// transport-level behaviour to - diagnostic instrumentation for
    /// `findings.md` §12.4, never anything that changes what the channel
    /// does. `nil` everywhere except `SystemLaunchServices.makeSession()`,
    /// which supplies one only when launched with `--probe=channeltrace`.
    /// When supplied, it wins over whatever `transport` would otherwise be -
    /// explicit or defaulted - because tracing only makes sense wired into
    /// the `URLSessionTransport` this call builds for itself; nothing in this
    /// repo ever passes both at once. `MacHost` hands over a plain `URL`
    /// rather than a `ChannelTraceSink` because that protocol, like
    /// `HTTPTransport`, is a `GChatBridgeCore` type this package's app-facing
    /// surface must not carry - `ChannelTraceFileSink` (in the
    /// `URLSessionTransport` target, next to `NWPathReachabilityMonitor`, for
    /// the identical containment reason) is what actually conforms to it.
    static func using(
        _ store: KeychainCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        reachability: (any ReachabilityMonitor)? = NWPathReachabilityMonitor(),
        tracingChannelTo traceFile: URL? = nil
    ) async throws -> LocalBridgeBackend? {
        let transport = traceFile
            .map { URLSessionTransport(channelTrace: ChannelTraceFileSink(writingTo: $0)) }
            ?? transport
        return try await using(store, transport: transport, retry: .default, reachability: reachability)
    }
}

extension LocalBridgeBackend {
    /// `using(_:transport:)` with the channel's reconnect backoff supplied.
    ///
    /// Internal for the same reason the initialiser it forwards to is:
    /// `RetryPolicy` is a `GChatBridgeCore` type and must not appear in a
    /// signature the app can see. The public overload above is unchanged.
    static func using(
        _ store: KeychainCredentialStore,
        transport: any HTTPTransport,
        retry: RetryPolicy,
        reachability: (any ReachabilityMonitor)? = nil
    ) async throws -> LocalBridgeBackend? {
        guard let session = try await store.currentSession() else { return nil }
        return LocalBridgeBackend(
            cookies: session.credential,
            transport: transport,
            retry: retry,
            // Closing the loop the cookie jar exists for. `findings.md` §12.3:
            // the `*SIDCC` family rotates on every poll cycle, so a session
            // that is not written back goes stale between one launch and the
            // next even though nobody signed out.
            onRotation: { rotated in
                // The capture date and expiry are **not** refreshed. A rotation
                // is the same session continuing, and treating it as a fresh
                // login would keep resetting the age of a credential that is no
                // younger - which would make the nine-day `COMPASS` fuse look
                // like it never burned down.
                try? await store.replaceCredential(with: rotated)
            },
            reachability: reachability
        )
    }
}

public extension KeychainCredentialStore {
    /// The account the self-check writes to.
    ///
    /// Separate from `defaultAccount` so running a diagnostic can never destroy
    /// somebody's live session - the check deletes what it wrote, and pointing
    /// it at the real account would make that deletion a logout.
    static let selfCheckAccount = "selfcheck"

    /// A store aimed at the self-check account.
    static func forSelfCheck() -> KeychainCredentialStore {
        KeychainCredentialStore(account: selfCheckAccount)
    }

    /// The account the data-protection probe writes to.
    ///
    /// Distinct from `selfCheckAccount` because the two keychains are separate
    /// stores: writing both probes to one account name would still be two
    /// items, and naming them apart is what makes a report saying "legacy PASS,
    /// data-protection FAIL" unambiguous about which item it means.
    static let dataProtectionSelfCheckAccount = "selfcheck-dp"

    /// Round-trips a throwaway credential and reports whether it worked.
    ///
    /// Whether this app can use the Keychain at all depends on how it was
    /// signed rather than on anything in this repository, and the failure is a
    /// silent `-34018` that reads exactly like "no session stored". So the
    /// question gets asked directly, and the answer is a sentence rather than a
    /// status code.
    func selfCheck() async -> String {
        let probe = StoredSession(
            credential: SessionCookies(cookies: [
                SessionCookies.Cookie(name: "GCHAT-SELFCHECK", value: "not-a-credential")
            ])!,
            capturedAt: Date(timeIntervalSince1970: 0),
            expiresAt: nil
        )
        do {
            try await store(probe)
            let read = try await currentSession()
            try await invalidate()
            guard read?.credential["GCHAT-SELFCHECK"] == "not-a-credential" else {
                return "FAIL - the Keychain accepted a write and returned something else."
            }
            return "PASS - this build can write and read the Keychain."
        } catch {
            // Best effort: if the write landed and the read failed, leaving the
            // probe behind would be litter.
            try? await invalidate()
            return "FAIL - \(KeychainDiagnosis.explain(error))"
        }
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
