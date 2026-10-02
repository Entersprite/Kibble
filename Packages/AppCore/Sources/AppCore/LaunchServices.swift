import ChatKit
import Foundation
import SyncEngine

/// Everything the launch machine needs from outside itself.
///
/// One protocol rather than three, because the launch machine's *job* is
/// composition: its dependency is the set of things to compose, and this
/// declares no logic of its own. Splitting it into custody / store / backend
/// protocols would make every test wire three fakes to exercise one decision.
///
/// **Every type in this seam belongs to `ChatKit` or `SyncEngine`.** No
/// `StoredSessionSummary`, no `KeychainDiagnosis`, no `KeychainCredentialStore`,
/// no `CookieCapture`. That is what keeps this package free of
/// `LocalBridgeBackend`, and `scripts/test.sh` is what keeps it that way. A
/// conformance may name whatever it likes; this file may not.
@MainActor
public protocol LaunchServices: AnyObject {
    var arguments: LaunchArguments { get }

    /// Whether a session is stored at all.
    ///
    /// **Throws** when the credential store refuses. "No credential" and
    /// "could not look" lead to opposite recoveries, and collapsing them
    /// sends someone through a two-factor login that cannot possibly help
    /// (`findings.md` §11). A `Bool` rather than a summary because the one
    /// call site only ever tests it for absence.
    func hasStoredSession() async throws -> Bool

    /// Forgets the stored session. Not a revocation: the session stays valid
    /// at Google until it expires on its own.
    func forgetStoredSession() async throws

    func openStore() throws -> ChatStore

    /// Erases the store at the standard path, with no live model to ask.
    /// Erasing an already-empty store is a cheap no-op, which is the point.
    func eraseStore() throws

    func makeSession() async throws -> SessionSelection

    /// Runs a diagnostic and returns a **short confirmation naming the file**
    /// the full report went to - never the report itself. See
    /// `LaunchPhase.report`.
    func runProbe(_ probe: LaunchProbe) async -> String

    /// Platform-chosen. On macOS this starts the App Nap probe; a future iOS
    /// conformance does nothing. Named neutrally so this package's vocabulary
    /// stays platform-free, not only its imports.
    func startDiagnostics() throws

    /// `--probe=markread`'s sink, or `nil` on every ordinary launch. Owns
    /// both the flag check and the file, exactly as `startDiagnostics()`
    /// owns the App Nap probe's - `AppEnvironment` only forwards whatever
    /// comes back into `ChatSessionModel.init`, unaware of the flag, the file
    /// or the concrete sink behind it.
    func markReadTraceSink() -> (any MarkReadTraceSink)?

    /// Where this launch's attachment cache keeps its files, or `nil` for a
    /// cache that keeps them in memory only. Separate per backend, for the
    /// reason the database is: a fixture's pictures must never appear in a
    /// real session. `eraseStore()` removes it too, for the path that signs
    /// out with no session to ask (`AttachmentCache`'s doc comment).
    func attachmentCacheDirectory() -> URL?

    /// The platform's half of a download: the folder, its sandbox access,
    /// Finder and the save panel. One instance for the process, because it
    /// holds the chosen folder.
    func downloadPlatform() -> any DownloadPlatform
}

/// What the launch was asked for, parsed once.
public struct LaunchArguments: Sendable, Equatable {
    public var usesRealBackend: Bool
    public var probe: LaunchProbe?
    public var runsDiagnostics: Bool

    public init(usesRealBackend: Bool = true, probe: LaunchProbe? = nil, runsDiagnostics: Bool = false) {
        self.usesRealBackend = usesRealBackend
        self.probe = probe
        self.runsDiagnostics = runsDiagnostics
    }

    /// The real process arguments. One line, so that everything above it is
    /// testable.
    public static func fromCommandLine() -> LaunchArguments {
        parsing(CommandLine.arguments)
    }

    /// Pure, so a test can supply a list.
    public static func parsing(_ arguments: [String]) -> LaunchArguments {
        LaunchArguments(
            // Inverted from `--backend=local` deliberately: what a person gets
            // by double-clicking the app is the real bridge.
            usesRealBackend: !arguments.contains("--backend=fixture"),
            probe: arguments.contains("--probe=keychain") ? .keychain
                : arguments.contains("--probe=api") ? .api
                : arguments.contains("--probe=punctual") ? .punctual : nil,
            runsDiagnostics: arguments.contains("--probe=appnap")
        )
    }
}

/// A diagnostic that replaces the launch rather than instrumenting it.
public enum LaunchProbe: Sendable, Equatable {
    case keychain
    case api
    /// Watches availability on Punctual for about ten minutes and reports the
    /// pushes' shapes (`findings.md` §47).
    case punctual
}

/// One backend, who we are, and the thing that drives a fake world.
public struct SessionSelection {
    public let backend: any ChatBackend
    public let me: Member.ID?
    /// Non-nil only for the fixture, which is the one that needs driving.
    public let driver: (any DemoDriver)?

    /// The "now" the Mentions list's 30-day backfill window reads. This is the
    /// wall clock, except for the fixture: its world is dated 2026-08-31, and
    /// against the wall clock its window would empty (ruling 8).
    public let now: @Sendable () -> Date

    public init(
        backend: any ChatBackend, me: Member.ID?, driver: (any DemoDriver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.me = me
        self.driver = driver
        self.now = now
    }
}

/// Something that makes a fake world move. `FixtureDemoDriver` conforms in
/// `MacHost`; this package must not name `FixtureBackend`.
public protocol DemoDriver: Sendable {
    func start() async
    func stop() async
}
