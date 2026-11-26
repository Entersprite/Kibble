import Foundation
import Sparkle

/// The one file that imports Sparkle (`scripts/test.sh` enforces it).
///
/// A thin conformance: every decision is `UpdateSettingsModel`'s, tested
/// against a fake, and this file only forwards, logs and keeps Sparkle's
/// install-now block. It cannot be unit-tested, because a started
/// `SPUUpdater` reads the main bundle's feed and key.
///
/// Sparkle's standard user driver supplies every window: the update offer
/// with its notes, progress, errors and "You're up to date". Its delegate
/// (`SparkleEvents`) logs what each step came to (`UpdateLog`) and takes over
/// an update downloaded in the background, for Restart to Update.
@MainActor
public final class SparkleUpdater: AppUpdating {
    /// Sparkle holds its delegate weakly, so it lives here.
    private let events = SparkleEvents()
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []
    /// Sparkle's block that installs the waiting update and relaunches.
    private var installWaitingUpdate: (() -> Void)?
    public private(set) var readyVersion: String?
    public var onChange: (@MainActor () -> Void)?

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: events, userDriverDelegate: nil
        )
        events.updateIsReady = { [weak self] version, install in
            guard let self else { return }
            installWaitingUpdate = install
            readyVersion = version
            onChange?()
        }
        // A waiting update holds its cycle open until it installs or fails,
        // so once the cycle ends there is nothing left to restart for.
        events.cycleFinished = { [weak self] in
            guard let self, readyVersion != nil else { return }
            installWaitingUpdate = nil
            readyVersion = nil
            onChange?()
        }
    }

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

    /// Kept after use: Sparkle accepts the block again if the quit it asks
    /// for is canceled (`SPUUpdaterDelegate.h`).
    public func installNow() {
        installWaitingUpdate?()
    }
}

/// Sparkle's updater delegate. Logs each step, and answers an update
/// downloaded in the background by keeping the block that installs it now,
/// so Restart to Update can run it; Sparkle installs it on quit regardless.
/// Answering `true` also stops Sparkle's further checks until then, which is
/// why Check Now is unavailable while an update waits.
@MainActor
private final class SparkleEvents: NSObject, SPUUpdaterDelegate {
    var updateIsReady: ((String, @escaping () -> Void) -> Void)?
    var cycleFinished: (() -> Void)?

    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        UpdateLog.readyToInstall()
        updateIsReady?(item.displayVersionString, immediateInstallHandler)
        return true
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateLog.found(
            critical: item.isCriticalUpdate,
            informationOnly: item.isInformationOnlyUpdate,
            majorUpgrade: item.isMajorUpgrade
        )
    }

    func updater(_: SPUUpdater, didDownloadUpdate _: SUAppcastItem) {
        UpdateLog.downloaded()
    }

    func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error: any Error) {
        UpdateLog.downloadFailed(error)
    }

    func updater(_: SPUUpdater, willInstallUpdate _: SUAppcastItem) {
        UpdateLog.installing()
    }

    func updaterWillRelaunchApplication(_: SPUUpdater) {
        UpdateLog.relaunching()
    }

    func updater(
        _: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate _: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        UpdateLog.choice(Self.name(choice), stage: Self.name(state.stage), userInitiated: state.userInitiated)
    }

    func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        UpdateLog.aborted(error)
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        UpdateLog.cycleFinished(check: Self.name(updateCheck), error: error)
        cycleFinished?()
    }

    func updater(_: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        UpdateLog.scheduled(after: delay)
    }

    func updaterWillNotScheduleUpdateCheck(_: SPUUpdater) {
        UpdateLog.notScheduled()
    }

    private static func name(_ check: SPUUpdateCheck) -> String {
        switch check {
        case .updates: "manual"
        case .updatesInBackground: "background"
        case .updateInformation: "information"
        @unknown default: "unknown(\(check.rawValue))"
        }
    }

    private static func name(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .skip: "skip"
        case .install: "install"
        case .dismiss: "dismiss"
        @unknown default: "unknown(\(choice.rawValue))"
        }
    }

    private static func name(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded: "notDownloaded"
        case .downloaded: "downloaded"
        case .installing: "installing"
        @unknown default: "unknown(\(stage.rawValue))"
        }
    }
}
