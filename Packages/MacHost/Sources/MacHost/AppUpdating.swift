import Foundation

/// The updater as `UpdateSettingsModel` drives it. `SparkleUpdater` is the one
/// real conformance and the only file that imports Sparkle, so every decision
/// above it is tested against a fake - the `SecretStorage` arrangement.
@MainActor
public protocol AppUpdating: AnyObject {
    /// False before `start()`, while a check is running, and after a failed start.
    var canCheck: Bool { get }
    var lastChecked: Date? { get }
    /// The updater's own scheduler.
    var automaticallyChecks: Bool { get set }
    var checkInterval: TimeInterval { get set }
    var automaticallyInstalls: Bool { get set }
    /// Called whenever `canCheck` or `lastChecked` may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
    func start() throws
    /// A check the person asked for: the updater shows its result either way.
    func checkNow()
    /// A quiet check: the updater shows something only when there is an update.
    func checkInBackground()
}
