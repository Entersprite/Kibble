import DesignSystem
import Foundation
import os

/// What the updater did, in the unified log, so an automatic update that
/// never arrives leaves a trace that can be read with `log show` rather than
/// copied out of the sandbox, as `PresenceLog` does. Settings, booleans, step
/// names and an error's domain and code only: no version, no URL, no id.
///
///     /usr/bin/log show --last 1d --predicate \
///         'subsystem == "com.entersprite.kibble" && category == "updates"'
///
/// The full path, because in zsh `log` is a shell builtin.
enum UpdateLog {
    private static let log = Logger(subsystem: "com.entersprite.kibble", category: "updates")

    /// What the model told the updater before starting it.
    static func started(atLaunch: Bool, frequency: UpdateFrequency, installs: Bool) {
        log.notice(
            """
            started atLaunch=\(atLaunch, privacy: .public) \
            frequency=\(frequency.rawValue, privacy: .public) installs=\(installs, privacy: .public)
            """
        )
    }

    static func startFailed(_ error: any Error) {
        log.notice("start failed \(describe(error), privacy: .public)")
    }

    static func launchCheck() {
        log.notice("launch check")
    }

    static func found(critical: Bool, informationOnly: Bool, majorUpgrade: Bool) {
        log.notice(
            """
            found critical=\(critical, privacy: .public) \
            informationOnly=\(informationOnly, privacy: .public) \
            majorUpgrade=\(majorUpgrade, privacy: .public)
            """
        )
    }

    static func downloaded() {
        log.notice("downloaded")
    }

    static func downloadFailed(_ error: any Error) {
        log.notice("download failed \(describe(error), privacy: .public)")
    }

    /// Downloaded, checked and waiting: installs on quit, or on Restart to Update.
    static func readyToInstall() {
        log.notice("ready to install on quit")
    }

    static func restartRequested(ready: Bool) {
        log.notice("restart to update requested ready=\(ready, privacy: .public)")
    }

    static func installing() {
        log.notice("installing")
    }

    static func relaunching() {
        log.notice("relaunching")
    }

    /// A choice in Sparkle's own update window: install, dismiss or skip.
    static func choice(_ choice: String, stage: String, userInitiated: Bool) {
        log.notice(
            """
            choice=\(choice, privacy: .public) stage=\(stage, privacy: .public) \
            userInitiated=\(userInitiated, privacy: .public)
            """
        )
    }

    static func aborted(_ error: any Error) {
        log.notice("aborted \(describe(error), privacy: .public)")
    }

    /// The end of every check, with `none` when it ended without an error.
    /// No update found ends with Sparkle's code 1001.
    static func cycleFinished(check: String, error: (any Error)?) {
        let outcome = error.map(describe) ?? "error=none"
        log.notice("cycle finished check=\(check, privacy: .public) \(outcome, privacy: .public)")
    }

    static func scheduled(after delay: TimeInterval) {
        log.notice("next check scheduled seconds=\(Int(delay), privacy: .public)")
    }

    static func notScheduled() {
        log.notice("no check scheduled")
    }

    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "domain=\(error.domain) code=\(error.code)"
    }
}
