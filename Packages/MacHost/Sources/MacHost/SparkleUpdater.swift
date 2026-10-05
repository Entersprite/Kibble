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
    private var observation: NSKeyValueObservation?
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

    /// Observes `canCheckForUpdates` only. `lastUpdateCheckDate` is not
    /// documented as KVO-compliant (`SPUUpdater.h`, Sparkle 2.10), but a
    /// check that ends flips `canCheckForUpdates` back, and the model reads
    /// both on every change.
    public func start() throws {
        try updater.start()
        observation = updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    public func checkNow() {
        updater.checkForUpdates()
    }

    public func checkInBackground() {
        updater.checkForUpdatesInBackground()
    }
}
