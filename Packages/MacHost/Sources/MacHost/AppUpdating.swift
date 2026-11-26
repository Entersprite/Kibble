import Foundation

/// The updater as `UpdateSettingsModel` drives it. `SparkleUpdater` is the one
/// real conformance and the only file that imports Sparkle, so every decision
/// above it is tested against a fake - the `SecretStorage` arrangement.
@MainActor
public protocol AppUpdating: AnyObject {
    /// False before `start()`, while a check is running, while a downloaded
    /// update waits to install, and after a failed start.
    var canCheck: Bool { get }
    var lastChecked: Date? { get }
    /// The updater's own scheduler.
    var automaticallyChecks: Bool { get set }
    var checkInterval: TimeInterval { get set }
    var automaticallyInstalls: Bool { get set }
    /// The version of an update downloaded in the background and waiting to
    /// install, or `nil`. It installs when Kibble quits, or at `installNow()`.
    var readyVersion: String? { get }
    /// Called whenever `canCheck`, `lastChecked` or `readyVersion` may have
    /// changed.
    var onChange: (@MainActor () -> Void)? { get set }
    func start() throws
    /// A check the person asked for: the updater shows its result either way.
    func checkNow()
    /// A quiet check: the updater shows something only when there is an update.
    func checkInBackground()
    /// Installs the waiting update now and relaunches; nothing without one.
    func installNow()
}
