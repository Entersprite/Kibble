import DesignSystem
import Foundation
import Observation

/// Settings › Updates, and every decision behind it.
///
/// **The model is the source of truth for the four settings**, under its own
/// keys, and pushes what they mean into the updater. Sparkle keeps settings
/// under its own keys too, but a check at launch is not one of its settings,
/// so its keys cannot hold the person's choice. They are derived state,
/// overwritten at every `start()`.
@MainActor
@Observable
public final class UpdateSettingsModel {
    static let automaticKey = "updatesCheckAutomatically"
    static let frequencyKey = "updatesFrequency"
    static let installKey = "updatesInstallAutomatically"
    static let launchKey = "updatesCheckAtLaunch"

    /// *At Launch* keeps the scheduler on, weekly. Measured: with Sparkle's
    /// scheduler off, a background check fetches the feed and downloads
    /// nothing, so automatic install would never happen.
    static let atLaunchBackstop: TimeInterval = 604_800

    /// One quiet check right after the updater starts, whatever the periodic
    /// schedule says, so each launch looks for the newest release. On by
    /// default, and the model's own: Sparkle's scheduler only knows intervals.
    /// Sparkle's header advises making this call only while its automatic
    /// checks are on; that guards the permission prompt it shows on a second
    /// launch, which `SUEnableAutomaticChecks` in `Info.plist` turns off, so
    /// with the scheduler off the check still runs and nothing is scheduled
    /// after it (`SPUUpdater.m`, Sparkle 2.10).
    public private(set) var checksAtLaunch: Bool
    public private(set) var automaticallyChecks: Bool
    public private(set) var frequency: UpdateFrequency
    /// The person's choice, kept while automatic checks are off; the updater
    /// only sees it while they are on.
    public private(set) var automaticallyInstalls: Bool
    public private(set) var canCheck = false
    public private(set) var lastChecked: Date?
    public private(set) var notice: String?
    public let version: String

    @ObservationIgnored private let updater: (any AppUpdating)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    /// What `apply()` last told the updater about automatic install, so a
    /// different value seen later is known to be someone else's write.
    @ObservationIgnored private var pushedInstalls: Bool?

    /// `updater` is `nil` in a development build, which never checks.
    public init(updater: (any AppUpdating)?, defaults: UserDefaults, version: String) {
        self.updater = updater
        self.defaults = defaults
        self.version = version
        let storedAutomatic = defaults.object(forKey: Self.automaticKey) as? Bool
        automaticallyChecks = storedAutomatic ?? true
        // Someone who turned automatic checks off before the launch check
        // existed asked for no checks they did not start themselves.
        checksAtLaunch = defaults.object(forKey: Self.launchKey) as? Bool ?? (storedAutomatic != false)
        frequency = defaults.string(forKey: Self.frequencyKey)
            .flatMap(UpdateFrequency.init(rawValue:)) ?? .daily
        automaticallyInstalls = defaults.object(forKey: Self.installKey) as? Bool ?? false
    }

    /// Whether this build checks for updates at all: `KibbleUpdatesEnabled`
    /// in `Info.plist`, `YES` in Release and `NO` in Debug. Build-setting
    /// substitution always produces a string, so only the string counts.
    public nonisolated static func isEnabled(infoValue: Any?) -> Bool {
        (infoValue as? String) == "YES"
    }

    /// Once, at launch. Settings first, so the scheduler starts on the right
    /// interval; then the updater; then the launch check. Sparkle starts its
    /// own schedule one run loop turn after `start()`, finds this check in
    /// progress and leaves it be, then schedules from its end.
    public func start() {
        guard let updater, !started else { return }
        started = true
        apply()
        updater.onChange = { [weak self] in self?.refresh() }
        do {
            try updater.start()
        } catch {
            notice = "Kibble couldn't start checking for updates: \(error.localizedDescription)"
            refresh()
            return
        }
        refresh()
        if checksAtLaunch {
            updater.checkInBackground()
        }
    }

    public func checkNow() {
        guard canCheck else { return }
        updater?.checkNow()
    }

    /// Turning it on checks nothing now: the next check is the next launch.
    public func setChecksAtLaunch(_ isOn: Bool) {
        checksAtLaunch = isOn
        defaults.set(isOn, forKey: Self.launchKey)
    }

    public func setAutomaticallyChecks(_ isOn: Bool) {
        automaticallyChecks = isOn
        defaults.set(isOn, forKey: Self.automaticKey)
        apply()
    }

    /// Choosing *At Launch* checks nothing now: the next check is the launch
    /// check, if it is on, or the weekly backstop.
    public func setFrequency(_ frequency: UpdateFrequency) {
        self.frequency = frequency
        defaults.set(frequency.rawValue, forKey: Self.frequencyKey)
        apply()
    }

    public func setAutomaticallyInstalls(_ isOn: Bool) {
        automaticallyInstalls = isOn
        defaults.set(isOn, forKey: Self.installKey)
        apply()
    }

    public var state: UpdateSettingsState {
        UpdateSettingsState(
            version: version,
            isEnabled: updater != nil,
            canCheck: canCheck,
            lastChecked: lastChecked,
            checksAtLaunch: checksAtLaunch,
            automaticallyChecks: automaticallyChecks,
            frequency: frequency,
            automaticallyInstalls: automaticallyInstalls,
            notice: notice
        )
    }

    public var actions: UpdateSettingsActions {
        UpdateSettingsActions(
            checkNow: { [weak self] in self?.checkNow() },
            setChecksAtLaunch: { [weak self] in self?.setChecksAtLaunch($0) },
            setAutomaticallyChecks: { [weak self] in self?.setAutomaticallyChecks($0) },
            setFrequency: { [weak self] in self?.setFrequency($0) },
            setAutomaticallyInstalls: { [weak self] in self?.setAutomaticallyInstalls($0) }
        )
    }

    private func apply() {
        guard let updater else { return }
        updater.automaticallyChecks = automaticallyChecks
        updater.checkInterval = switch frequency {
        case .hourly: 3600
        case .daily: 86400
        case .atLaunch: Self.atLaunchBackstop
        }
        let installs = automaticallyChecks && automaticallyInstalls
        updater.automaticallyInstalls = installs
        pushedInstalls = installs
    }

    /// Also adopts a change to automatic install that the model did not make:
    /// Sparkle's update window has its own "Automatically download and install
    /// updates" checkbox, which writes the setting directly. Without this the
    /// pane would show the old choice and the next `start()` would undo the
    /// person's (final review, session 49).
    private func refresh() {
        guard let updater else { return }
        canCheck = notice == nil && updater.canCheck
        lastChecked = updater.lastChecked
        if let pushedInstalls, updater.automaticallyInstalls != pushedInstalls {
            automaticallyInstalls = updater.automaticallyInstalls
            defaults.set(automaticallyInstalls, forKey: Self.installKey)
            self.pushedInstalls = updater.automaticallyInstalls
        }
    }
}
