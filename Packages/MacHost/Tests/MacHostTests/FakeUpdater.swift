import Foundation
@testable import MacHost

@MainActor
final class FakeUpdater: AppUpdating {
    var canCheck = false
    var lastChecked: Date?
    var automaticallyChecks = true
    var checkInterval: TimeInterval = 0
    var automaticallyInstalls = false
    var onChange: (@MainActor () -> Void)?

    var startError: (any Error)?
    /// What `canCheck` reads after a failed start. Sparkle's answer there is
    /// not documented, so the model must not depend on it.
    var canCheckAfterFailedStart = false
    private(set) var starts = 0
    private(set) var manualChecks = 0
    private(set) var backgroundChecks = 0
    struct Settings {
        var checks: Bool
        var interval: TimeInterval
        var installs: Bool
    }

    /// What the scheduler held at the moment `start()` ran.
    private(set) var settingsAtStart: Settings?

    func start() throws {
        starts += 1
        settingsAtStart = Settings(
            checks: automaticallyChecks,
            interval: checkInterval,
            installs: automaticallyInstalls
        )
        if let startError {
            canCheck = canCheckAfterFailedStart
            throw startError
        }
        canCheck = true
    }

    func checkNow() {
        manualChecks += 1
    }

    func checkInBackground() {
        backgroundChecks += 1
    }

    /// Stands in for the updater finishing a check.
    func finishCheck(at date: Date) {
        lastChecked = date
        onChange?()
    }
}
