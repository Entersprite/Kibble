import DesignSystem
import Foundation
import Testing
@testable import MacHost

/// Choices stored by earlier versions, read by today's model: an explicit
/// choice wins over a new default, and the old keys are gone afterwards.
@MainActor
struct UpdateSettingsMigrationTests {
    private func defaults(_ stored: [String: Any]) throws -> UserDefaults {
        let name = "kibble-updates-migration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        for (key, value) in stored {
            defaults.set(value, forKey: key)
        }
        return defaults
    }

    /// What an earlier version stored (`automatic`, `frequency`, `launch`;
    /// nil for never written) and what today's model reads from it.
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var automatic: Bool?
        var frequency: String?
        var launch: Bool?
        var expectedFrequency: UpdateFrequency
        var expectedLaunch: Bool
        var testDescription: String {
            name
        }

        init(
            _ name: String, automatic: Bool? = nil, frequency: String? = nil, launch: Bool? = nil,
            becomes expectedFrequency: UpdateFrequency, launchCheck expectedLaunch: Bool
        ) {
            self.name = name
            self.automatic = automatic
            self.frequency = frequency
            self.launch = launch
            self.expectedFrequency = expectedFrequency
            self.expectedLaunch = expectedLaunch
        }
    }

    @Test("Earlier choices map to today's settings", arguments: [
        Case("nothing stored", becomes: .daily, launchCheck: true),
        Case("checks off", automatic: false, frequency: "daily", becomes: .never, launchCheck: false),
        Case(
            "checks off, At Launch",
            automatic: false,
            frequency: "atLaunch",
            becomes: .never,
            launchCheck: false
        ),
        Case("checks off, nothing else", automatic: false, becomes: .never, launchCheck: false),
        Case(
            "checks off, launch chosen since", automatic: false, frequency: "hourly", launch: true,
            becomes: .never, launchCheck: true
        ),
        Case("At Launch", automatic: true, frequency: "atLaunch", becomes: .weekly, launchCheck: true),
        Case("At Launch, toggle never touched", frequency: "atLaunch", becomes: .weekly, launchCheck: true),
        Case(
            "At Launch, launch off since",
            frequency: "atLaunch",
            launch: false,
            becomes: .weekly,
            launchCheck: false
        ),
        Case("Every Hour", automatic: true, frequency: "hourly", becomes: .hourly, launchCheck: true),
        Case("Every Day", automatic: true, frequency: "daily", becomes: .daily, launchCheck: true),
        Case("today's Never", frequency: "never", becomes: .never, launchCheck: true),
        Case("today's Every Week", frequency: "weekly", launch: false, becomes: .weekly, launchCheck: false)
    ])
    func migration(_ example: Case) throws {
        var stored: [String: Any] = [:]
        stored[UpdateSettingsModel.legacyAutomaticKey] = example.automatic
        stored[UpdateSettingsModel.frequencyKey] = example.frequency
        stored[UpdateSettingsModel.launchKey] = example.launch
        let store = try defaults(stored)
        let fake = FakeUpdater()
        let model = UpdateSettingsModel(updater: fake, defaults: store, version: "1")
        model.start()
        #expect(model.state.frequency == example.expectedFrequency)
        #expect(model.state.checksAtLaunch == example.expectedLaunch)
        #expect(fake.automaticallyChecks == (example.expectedFrequency != .never))
        #expect(fake.backgroundChecks == (example.expectedLaunch ? 1 : 0))
        #expect(store.object(forKey: UpdateSettingsModel.legacyAutomaticKey) == nil)
        #expect(store.string(forKey: UpdateSettingsModel.frequencyKey) != UpdateSettingsModel.legacyAtLaunch)
    }

    /// Choosing a frequency after the move is not undone by an old key that
    /// a read-time mapping would still find.
    @Test func aChoiceMadeAfterTheMoveSticks() throws {
        let store = try defaults([UpdateSettingsModel.legacyAutomaticKey: false])
        let first = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        first.setFrequency(.daily)
        let second = UpdateSettingsModel(updater: FakeUpdater(), defaults: store, version: "1")
        #expect(second.state.frequency == .daily)
        #expect(second.state.checksAtLaunch == false)
    }

    @Test func movingTwiceChangesNothing() throws {
        let store = try defaults([
            UpdateSettingsModel.legacyAutomaticKey: true,
            UpdateSettingsModel.frequencyKey: "atLaunch"
        ])
        UpdateSettingsModel.migrate(store)
        let once = store.dictionaryRepresentation().filter { $0.key.hasPrefix("updates") }
        UpdateSettingsModel.migrate(store)
        let twice = store.dictionaryRepresentation().filter { $0.key.hasPrefix("updates") }
        #expect(once as NSDictionary == twice as NSDictionary)
        #expect(store.string(forKey: UpdateSettingsModel.frequencyKey) == "weekly")
    }

    /// An install choice stored earlier stays; under Never the updater does
    /// not see it.
    @Test func anEarlierInstallChoiceIsKept() throws {
        let store = try defaults([
            UpdateSettingsModel.legacyAutomaticKey: false,
            UpdateSettingsModel.installKey: true
        ])
        let fake = FakeUpdater()
        let model = UpdateSettingsModel(updater: fake, defaults: store, version: "1")
        model.start()
        #expect(model.state.automaticallyInstalls == true)
        #expect(fake.automaticallyInstalls == false)
    }
}
