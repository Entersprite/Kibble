import DesignSystem
import Foundation
import Observation

/// Settings › Updates, and every decision behind it.
///
/// **The model is the source of truth for the three settings**, under its own
/// keys, and pushes what they mean into the updater. Sparkle keeps settings
/// under its own keys too, but a check at launch is not one of its settings,
/// so its keys cannot hold the person's choice. They are derived state,
/// overwritten at every `start()`.
///
/// **Choices stored by earlier versions are moved once, in `init`**
/// (`migrate`): an explicit choice always wins over a new default.
@MainActor
@Observable
public final class UpdateSettingsModel {
    static let frequencyKey = "updatesFrequency"
    static let installKey = "updatesInstallAutomatically"
    static let launchKey = "updatesCheckAtLaunch"
    /// Earlier versions' "Check for updates automatically", now Never or not;
    /// read only by `migrate`.
    static let legacyAutomaticKey = "updatesCheckAutomatically"
    /// Earlier versions' *At Launch*, which kept a weekly scheduler under the
    /// launch check; read only by `migrate`.
    static let legacyAtLaunch = "atLaunch"

    /// One quiet check right after the updater starts, whatever the periodic
    /// schedule says, so each launch looks for the newest release. On by
    /// default, and the model's own: Sparkle's scheduler only knows intervals.
    /// Sparkle's header advises making this call only while its automatic
    /// checks are on; that guards the permission prompt it shows on a second
    /// launch, which `SUEnableAutomaticChecks` in `Info.plist` turns off, so
    /// with the scheduler off the check still runs and nothing is scheduled
    /// after it (`SPUUpdater.m`, Sparkle 2.10).
    public private(set) var checksAtLaunch: Bool
    /// Sparkle's scheduler: off for Never, otherwise on at the interval.
    public private(set) var frequency: UpdateFrequency
    /// The person's choice, kept under Never; the updater only sees it while
    /// its scheduler runs. Measured: with Sparkle's scheduler off, a
    /// background check fetches the feed and downloads nothing, so automatic
    /// install would never happen.
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
        Self.migrate(defaults)
        checksAtLaunch = defaults.object(forKey: Self.launchKey) as? Bool ?? true
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

    /// Moves earlier versions' choices into today's vocabulary, so every
    /// later read is plain, and leaves anything already stored as it is:
    /// - automatic checks turned off become Never, with the launch check off
    ///   unless it was chosen since: that person asked for no check they did
    ///   not start themselves;
    /// - *At Launch* becomes Every Week, its old weekly backstop, and the
    ///   launch check, on by default, carries on its check at launch;
    /// - Every Hour and Every Day stay.
    static func migrate(_ defaults: UserDefaults) {
        if let automatic = defaults.object(forKey: legacyAutomaticKey) as? Bool {
            if !automatic {
                defaults.set(UpdateFrequency.never.rawValue, forKey: frequencyKey)
                if defaults.object(forKey: launchKey) == nil {
                    defaults.set(false, forKey: launchKey)
                }
            }
            defaults.removeObject(forKey: legacyAutomaticKey)
        }
        if defaults.string(forKey: frequencyKey) == legacyAtLaunch {
            defaults.set(UpdateFrequency.weekly.rawValue, forKey: frequencyKey)
        }
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

    /// Sparkle restarts its schedule from the last check, so an interval that
    /// has already passed since then checks within moments.
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
            frequency: frequency,
            automaticallyInstalls: automaticallyInstalls,
            notice: notice
        )
    }

    public var actions: UpdateSettingsActions {
        UpdateSettingsActions(
            checkNow: { [weak self] in self?.checkNow() },
            setChecksAtLaunch: { [weak self] in self?.setChecksAtLaunch($0) },
            setFrequency: { [weak self] in self?.setFrequency($0) },
            setAutomaticallyInstalls: { [weak self] in self?.setAutomaticallyInstalls($0) }
        )
    }

    private func apply() {
        guard let updater else { return }
        updater.automaticallyChecks = frequency != .never
        // Under Never the interval is left as it was: Sparkle reads an
        // interval of 0 as automatic checks off, from its oldest settings.
        if let interval = Self.interval(frequency) {
            updater.checkInterval = interval
        }
        let installs = frequency != .never && automaticallyInstalls
        updater.automaticallyInstalls = installs
        pushedInstalls = installs
    }

    static func interval(_ frequency: UpdateFrequency) -> TimeInterval? {
        switch frequency {
        case .never: nil
        case .hourly: 3600
        case .daily: 86400
        case .weekly: 604_800
        }
    }

    /// Also adopts a change to automatic install that the model did not make:
    /// Sparkle's update window has its own "Automatically download and install
    /// updates" checkbox, which writes the setting directly. Without this the
    /// pane would show the old choice and the next `start()` would undo the
    /// person's.
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
