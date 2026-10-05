import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
struct UpdateSettingsModelTests {
    private func defaults() throws -> UserDefaults {
        let name = "kibble-updates-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private struct StartFailure: LocalizedError {
        var errorDescription: String? {
            "no public key"
        }
    }

    /// Review Focus 2.
    @Test func freshDefaultsCheckDailyAndDoNotInstall() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "2026.41.1")
        model.start()
        #expect(fake.settingsAtStart?.checks == true)
        #expect(fake.settingsAtStart?.interval == 86400)
        #expect(fake.settingsAtStart?.installs == false)
        #expect(fake.backgroundChecks == 0)
        #expect(model.state.frequency == .daily)
    }

    /// Review Focus 2: whatever the updater's own keys held, the model's win.
    @Test func startOverwritesWhateverTheUpdaterHeld() throws {
        let store = try defaults()
        store.set(UpdateFrequency.atLaunch.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        let fake = FakeUpdater()
        fake.automaticallyChecks = false
        fake.checkInterval = 3600
        fake.automaticallyInstalls = true
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.settingsAtStart?.checks == true)
        #expect(fake.settingsAtStart?.interval == 604_800)
        #expect(fake.settingsAtStart?.installs == false)
    }

    /// *At launch* keeps the scheduler on, weekly, because Sparkle downloads
    /// nothing from a background check while its scheduler is off (spike,
    /// session 49): the weekly check is the backstop, the launch check the point.
    @Test("Frequency maps to the scheduler", arguments: [
        (UpdateFrequency.hourly, 3600.0, 0),
        (.daily, 86400.0, 0),
        (.atLaunch, 604_800.0, 1)
    ])
    func frequencyMapping(_ frequency: UpdateFrequency, _ interval: Double, _ launchChecks: Int) throws {
        let store = try defaults()
        store.set(frequency.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        let fake = FakeUpdater()
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.automaticallyChecks == true)
        #expect(fake.checkInterval == interval)
        #expect(fake.backgroundChecks == launchChecks)
    }

    /// Review Focus 3.
    @Test func atLaunchWithAutomaticChecksOffMakesNoCheckAndInstallsNothing() throws {
        let store = try defaults()
        store.set(UpdateFrequency.atLaunch.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        store.set(false, forKey: UpdateSettingsModel.automaticKey)
        store.set(true, forKey: UpdateSettingsModel.installKey)
        let fake = FakeUpdater()
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.backgroundChecks == 0)
        #expect(fake.automaticallyChecks == false)
        #expect(fake.automaticallyInstalls == false)
    }

    @Test func choosingAtLaunchMidSessionChecksNothingNow() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.setFrequency(.atLaunch)
        #expect(fake.checkInterval == 604_800)
        #expect(fake.backgroundChecks == 0)
    }

    @Test func automaticInstallReachesTheUpdaterOnlyWhileCheckingAutomatically() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.setAutomaticallyInstalls(true)
        #expect(fake.automaticallyInstalls == true)
        model.setAutomaticallyChecks(false)
        #expect(fake.automaticallyInstalls == false)
        #expect(fake.automaticallyChecks == false)
        #expect(model.state.automaticallyInstalls == true) // the person's choice is kept
        model.setAutomaticallyChecks(true)
        #expect(fake.automaticallyInstalls == true)
    }

    @Test func choicesPersistAcrossInstances() throws {
        let store = try defaults()
        let first = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        first.setFrequency(.hourly)
        first.setAutomaticallyInstalls(true)
        first.setAutomaticallyChecks(false)
        let second = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        #expect(second.state.frequency == .hourly)
        #expect(second.state.automaticallyInstalls == true)
        #expect(second.state.automaticallyChecks == false)
    }

    @Test func aFinishedCheckUpdatesTheLastCheckedDate() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        fake.finishCheck(at: date)
        #expect(model.state.lastChecked == date)
    }

    @Test func checkNowRunsOnlyWhenTheUpdaterCan() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.checkNow() // before start: canCheck is false
        #expect(fake.manualChecks == 0)
        model.start()
        model.checkNow()
        #expect(fake.manualChecks == 1)
    }

    /// Review Focus 4.
    @Test func aFailedStartDisablesCheckNowAndSaysWhy() throws {
        let fake = FakeUpdater()
        fake.startError = StartFailure()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        #expect(model.state.canCheck == false)
        #expect(model.state.notice == "Kibble couldn't start checking for updates: no public key")
        #expect(fake.backgroundChecks == 0)
    }

    /// Review Focus 4: the notice decides, not whatever the updater reports
    /// after refusing to start.
    @Test func aFailedStartStaysUncheckableWhateverTheUpdaterClaims() throws {
        let fake = FakeUpdater()
        fake.startError = StartFailure()
        fake.canCheckAfterFailedStart = true
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.checkNow()
        #expect(model.state.canCheck == false)
        #expect(fake.manualChecks == 0)
    }

    @Test func startRunsOnce() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.start()
        #expect(fake.starts == 1)
    }

    @Test func aDevelopmentBuildHasNoUpdaterAndCannotCheck() throws {
        let model = try UpdateSettingsModel(updater: nil, defaults: defaults(), version: "1")
        model.start()
        model.checkNow()
        #expect(model.state.isEnabled == false)
        #expect(model.state.canCheck == false)
    }

    /// `Info.plist` build-setting substitution always produces a string, so a
    /// `Bool` is deliberately not accepted: one spelling, pinned.
    /// Written out rather than parameterised: arguments must be `Sendable`,
    /// and `Any?` is not.
    @Test func onlyTheLiteralYESEnablesUpdates() {
        #expect(UpdateSettingsModel.isEnabled(infoValue: "YES"))
        #expect(!UpdateSettingsModel.isEnabled(infoValue: "NO"))
        #expect(!UpdateSettingsModel.isEnabled(infoValue: nil))
        #expect(!UpdateSettingsModel.isEnabled(infoValue: true))
        #expect(!UpdateSettingsModel.isEnabled(infoValue: ""))
    }
}
