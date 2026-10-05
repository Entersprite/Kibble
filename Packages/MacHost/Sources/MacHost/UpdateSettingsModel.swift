import DesignSystem
import Foundation
import Observation

/// Settings › Updates, and every decision behind it.
///
/// **The model is the source of truth for the three settings**, under its own
/// keys, and pushes what they mean into the updater. Sparkle keeps settings
/// under its own keys too, but *At launch* is not one of its settings, so its
/// keys cannot hold the person's choice. They are derived state, overwritten
/// at every `start()`.
@MainActor
@Observable
public final class UpdateSettingsModel {
    static let automaticKey = "updatesCheckAutomatically"
    static let frequencyKey = "updatesFrequency"
    static let installKey = "updatesInstallAutomatically"

    /// *At launch* keeps the scheduler on, weekly, and checks once at start.
    /// Measured in session 49's spike: with Sparkle's scheduler off, a
    /// background check fetches the feed and downloads nothing, so automatic
    /// install would never happen; Sparkle's header says to make the launch
    /// check only while automatic checks are on.
    static let atLaunchBackstop: TimeInterval = 604_800

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

    /// `updater` is `nil` in a development build, which never checks.
    public init(updater: (any AppUpdating)?, defaults: UserDefaults, version: String) {
        self.updater = updater
        self.defaults = defaults
        self.version = version
        automaticallyChecks = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
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
    /// interval; then the updater; then *At launch*'s one check.
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
        if automaticallyChecks, frequency == .atLaunch {
            updater.checkInBackground()
        }
    }

    public func checkNow() {
        guard canCheck else { return }
        updater?.checkNow()
    }

    public func setAutomaticallyChecks(_ isOn: Bool) {
        automaticallyChecks = isOn
        defaults.set(isOn, forKey: Self.automaticKey)
        apply()
    }

    /// Choosing *At launch* checks nothing now: the next check is the next
    /// launch, or the weekly backstop.
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
            automaticallyChecks: automaticallyChecks,
            frequency: frequency,
            automaticallyInstalls: automaticallyInstalls,
            notice: notice
        )
    }

    public var actions: UpdateSettingsActions {
        UpdateSettingsActions(
            checkNow: { [weak self] in self?.checkNow() },
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
        updater.automaticallyInstalls = automaticallyChecks && automaticallyInstalls
    }

    private func refresh() {
        guard let updater else { return }
        canCheck = notice == nil && updater.canCheck
        lastChecked = updater.lastChecked
    }
}
