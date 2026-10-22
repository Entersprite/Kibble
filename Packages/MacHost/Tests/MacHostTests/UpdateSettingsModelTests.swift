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

    @Test func freshDefaultsCheckAtLaunchAndDailyAndDoNotInstall() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "2026.41.1")
        model.start()
        #expect(fake.settingsAtStart?.checks == true)
        #expect(fake.settingsAtStart?.interval == 86400)
        #expect(fake.settingsAtStart?.installs == false)
        #expect(fake.backgroundChecks == 1)
        #expect(model.state.checksAtLaunch == true)
        #expect(model.state.frequency == .daily)
    }

    /// Whatever the updater's own keys held, the model's win.
    @Test func startOverwritesWhateverTheUpdaterHeld() throws {
        let store = try defaults()
        store.set(UpdateFrequency.weekly.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        let fake = FakeUpdater()
        fake.automaticallyChecks = false
        fake.checkInterval = 3600
        fake.automaticallyInstalls = true
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.settingsAtStart?.checks == true)
        #expect(fake.settingsAtStart?.interval == 604_800)
        #expect(fake.settingsAtStart?.installs == false)
    }

    @Test("Frequency maps to the scheduler", arguments: [
        (UpdateFrequency.hourly, true, 3600.0),
        (.daily, true, 86400.0),
        (.weekly, true, 604_800.0),
        // Never leaves the interval alone: Sparkle reads 0 as checks off.
        (.never, false, 1234.0)
    ])
    func frequencyMapping(_ frequency: UpdateFrequency, _ scheduled: Bool, _ interval: Double) throws {
        let store = try defaults()
        store.set(frequency.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        let fake = FakeUpdater()
        fake.checkInterval = 1234
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.automaticallyChecks == scheduled)
        #expect(fake.checkInterval == interval)
    }

    @Test("The launch check follows its own setting, whatever the schedule", arguments: [
        (true, UpdateFrequency.daily, 1),
        (true, .never, 1),
        (false, .daily, 0),
        (false, .never, 0)
    ])
    func launchCheck(_ atLaunch: Bool, _ frequency: UpdateFrequency, _ checks: Int) throws {
        let store = try defaults()
        store.set(atLaunch, forKey: UpdateSettingsModel.launchKey)
        store.set(frequency.rawValue, forKey: UpdateSettingsModel.frequencyKey)
        let fake = FakeUpdater()
        UpdateSettingsModel(updater: fake, defaults: store, version: "1").start()
        #expect(fake.backgroundChecks == checks)
        #expect(fake.automaticallyChecks == (frequency != .never))
    }

    @Test func turningTheLaunchCheckOnMidSessionChecksNothingNow() throws {
        let store = try defaults()
        store.set(false, forKey: UpdateSettingsModel.launchKey)
        let fake = FakeUpdater()
        let model = UpdateSettingsModel(updater: fake, defaults: store, version: "1")
        model.start()
        model.setChecksAtLaunch(true)
        #expect(fake.backgroundChecks == 0)
        #expect(model.state.checksAtLaunch == true)
    }

    @Test func choosingAFrequencyMidSessionReachesTheScheduler() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.setFrequency(.never)
        #expect(fake.automaticallyChecks == false)
        model.setFrequency(.weekly)
        #expect(fake.automaticallyChecks == true)
        #expect(fake.checkInterval == 604_800)
        #expect(fake.backgroundChecks == 1) // the launch check only
    }

    @Test func automaticInstallReachesTheUpdaterOnlyWhileTheSchedulerRuns() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.setAutomaticallyInstalls(true)
        #expect(fake.automaticallyInstalls == true)
        model.setFrequency(.never)
        #expect(fake.automaticallyInstalls == false)
        #expect(model.state.automaticallyInstalls == true) // the person's choice is kept
        model.setFrequency(.daily)
        #expect(fake.automaticallyInstalls == true)
    }

    /// A choice made in Sparkle's own window is the person's, so the pane
    /// shows it and the next launch keeps it.
    @Test func aChoiceMadeInTheUpdateWindowIsAdoptedAndKept() throws {
        let store = try defaults()
        let fake = FakeUpdater()
        let model = UpdateSettingsModel(updater: fake, defaults: store, version: "1")
        model.start()
        fake.personSetsAutomaticInstallInUpdateWindow(true)
        #expect(model.state.automaticallyInstalls == true)
        let next = FakeUpdater()
        UpdateSettingsModel(updater: next, defaults: store, version: "1").start()
        #expect(next.settingsAtStart?.installs == true)
    }

    /// The model's own push of `false` under Never is not the person turning
    /// automatic install off.
    @Test func theModelsOwnPushIsNotMistakenForThePersonsChoice() throws {
        let fake = FakeUpdater()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        model.setAutomaticallyInstalls(true)
        model.setFrequency(.never)
        fake.onChange?()
        #expect(model.state.automaticallyInstalls == true)
    }

    @Test func choicesPersistAcrossInstances() throws {
        let store = try defaults()
        let first = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        first.setFrequency(.never)
        first.setAutomaticallyInstalls(true)
        first.setChecksAtLaunch(false)
        let second = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        #expect(second.state.checksAtLaunch == false)
        #expect(second.state.frequency == .never)
        #expect(second.state.automaticallyInstalls == true)
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

    @Test func aFailedStartDisablesCheckNowAndSaysWhy() throws {
        let fake = FakeUpdater()
        fake.startError = StartFailure()
        let model = try UpdateSettingsModel(updater: fake, defaults: defaults(), version: "1")
        model.start()
        #expect(model.state.canCheck == false)
        #expect(model.state.notice == "Kibble couldn't start checking for updates: no public key")
        #expect(fake.backgroundChecks == 0)
    }

    /// The notice decides, not whatever the updater reports after refusing
    /// to start.
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
