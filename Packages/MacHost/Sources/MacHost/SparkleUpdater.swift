import Foundation
import Sparkle

/// The one file that imports Sparkle (`scripts/test.sh` enforces it).
///
/// A thin conformance: every decision is `UpdateSettingsModel`'s, tested
/// against a fake, and this file only forwards. It cannot be unit-tested,
/// because a started `SPUUpdater` reads the main bundle's feed and key.
///
/// Sparkle's standard user driver supplies every window: the update offer
/// with its notes, progress, errors and "You're up to date".
@MainActor
public final class SparkleUpdater: AppUpdating {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var observations: [NSKeyValueObservation] = []
    public var onChange: (@MainActor () -> Void)?

    public init() {}

    private var updater: SPUUpdater {
        controller.updater
    }

    public var canCheck: Bool {
        updater.canCheckForUpdates
    }

    public var lastChecked: Date? {
        updater.lastUpdateCheckDate
    }

    public var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    public var checkInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }

    public var automaticallyInstalls: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Observes `canCheckForUpdates`, and `automaticallyDownloadsUpdates`,
    /// which Sparkle's own update window can change. `lastUpdateCheckDate` is
    /// not documented as KVO-compliant (`SPUUpdater.h`, Sparkle 2.10), but a
    /// check that ends flips `canCheckForUpdates` back, and the model reads
    /// everything on every change.
    public func start() throws {
        try updater.start()
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.onChange?() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in changed() },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in changed() }
        ]
    }

    public func checkNow() {
        updater.checkForUpdates()
    }

    public func checkInBackground() {
        updater.checkForUpdatesInBackground()
    }
}
