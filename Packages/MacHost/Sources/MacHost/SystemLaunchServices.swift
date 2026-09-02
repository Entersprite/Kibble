import AppCore
import ChatKit
import FixtureBackend
import Foundation
import LocalBridgeBackend
import SyncEngine

/// **The only file in the repo that names a concrete backend.**
///
/// Swapping the fixture for `LocalBridgeBackend` is a change to
/// `makeSession()` and nothing else - which is the property the whole package
/// layout exists to buy, so it is worth keeping literally true. `AppCore`
/// cannot hold this, because a future iOS app links `AppCore` and must contain
/// no protocol code at all.
@MainActor
public final class SystemLaunchServices: LaunchServices {
    public let arguments: LaunchArguments

    public init(arguments: LaunchArguments) {
        self.arguments = arguments
    }

    /// Whether anything is stored. Throws rather than answering `false` when
    /// the Keychain refuses: "no credential" and "could not look" lead to
    /// opposite recoveries, and collapsing them sends someone through a
    /// two-factor login that cannot possibly help.
    public func hasStoredSession() async throws -> Bool {
        do {
            return try await KeychainCredentialStore().summary(at: Date()) != nil
        } catch {
            throw ChatError.unknown(KeychainDiagnosis.explain(error))
        }
    }

    public func forgetStoredSession() async throws {
        try await KeychainCredentialStore().invalidate()
    }

    public func openStore() throws -> ChatStore {
        try ChatStore.onDisk(at: Self.databasePath(for: arguments))
    }

    public func eraseStore() throws {
        try ChatStore.onDisk(at: Self.databasePath(for: arguments)).erase()
    }

    /// The only place in the repo that picks a backend.
    ///
    /// Anything but `--backend=fixture` hosts `GChatBridgeCore` in-process
    /// through `LocalBridgeBackend`, using whatever session
    /// `hasStoredSession()` already confirmed is in the Keychain.
    public func makeSession() async throws -> SessionSelection {
        guard arguments.usesRealBackend else {
            let fixture = FakeBackend(world: .acme)
            return SessionSelection(
                backend: fixture,
                me: Acme.alex,
                driver: FixtureDemoDriver(backend: fixture)
            )
        }
        // The session comes from the Keychain, put there by the login window.
        // There is no longer a file to copy: a live Google session in plain
        // text inside the container was the developer escape hatch, and the
        // login window is what retired it.
        let backend: LocalBridgeBackend?
        do {
            backend = try await LocalBridgeBackend.using(KeychainCredentialStore())
        } catch {
            // A Keychain that refuses is not an absent credential, and
            // reporting it as one would send someone through a two-factor
            // login that cannot fix it.
            throw ChatError.unknown(KeychainDiagnosis.explain(error))
        }
        guard let backend else {
            throw ChatError.unknown(
                "No session in the Keychain. Open the login window and sign in."
            )
        }
        // `me` is nil only for the instant before the answer, not a standing
        // gap: `connect()` starts `get_self_user_status` in the background and
        // `ChatSessionModel.me` watches the store for it, so a message renders
        // as incoming for one heartbeat and then correctly as outgoing - never
        // a session-long "wrong-looking".
        return SessionSelection(backend: backend, me: nil, driver: nil)
    }

    // MARK: - Task 8 stubs

    // TASK 8 TODO: `LaunchProbes` and `AppNapProbe` move into this package in
    // Task 8. Until then these two bodies are stubs; replace both, and restore
    // the `appNapProbe` property (with its doc comment) that `startDiagnostics()`
    // needs. Do not move `LaunchProbes`/`AppNapProbe` early - that is this
    // task's job, not Task 5's.

    public func runProbe(_ probe: LaunchProbe) async -> String {
        "Probe \(probe) is not wired yet."
    }

    public func startDiagnostics() throws {}

    /// One database per backend, and that separation is load-bearing.
    ///
    /// **The views observe the store, not the backend**, so a single file
    /// shared between the two means the fixture's invented conversations are
    /// still on screen the next time a real session launches - indistinguishable
    /// from real ones. Two files, so it cannot happen.
    ///
    /// Split from `databasePath(for:)` so a test can assert the separation
    /// without needing a container.
    /// Not `throws`: it cannot fail. `databasePath(for:)` below keeps `throws`,
    /// which it genuinely needs through `supportDirectory()`. Ruling R5.
    static func databaseName(for arguments: LaunchArguments) -> String {
        arguments.usesRealBackend ? "chat-local.sqlite" : "chat-fixture.sqlite"
    }

    static func databasePath(for arguments: LaunchArguments) throws -> String {
        try supportDirectory().appendingPathComponent(databaseName(for: arguments)).path
    }

    /// Not `private`: the probes write their report files beside the same
    /// database, and this is the one place that path is computed.
    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GChat", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// `FixtureDemoDriver` already has exactly these two methods; this is the
/// retroactive conformance that keeps `FixtureBackend` out of `AppCore`.
///
/// `@retroactive` because both the type and the protocol are external to this
/// module, which is precisely the case Swift 6 requires the attribute for
/// (ruling R6). Confirm `FixtureDemoDriver`'s `start()`/`stop()` satisfy
/// `DemoDriver: Sendable` - it is an actor, so they should.
extension FixtureDemoDriver: @retroactive DemoDriver {}
