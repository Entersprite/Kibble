import Foundation
import Testing
@testable import DesignSystem

struct UpdateSettingsPaneTests {
    private func state(
        isEnabled: Bool = true,
        lastChecked: Date? = nil,
        automaticallyChecks: Bool = true,
        notice: String? = nil
    ) -> UpdateSettingsState {
        UpdateSettingsState(
            version: "2026.41.1",
            isEnabled: isEnabled,
            canCheck: true,
            lastChecked: lastChecked,
            automaticallyChecks: automaticallyChecks,
            frequency: .daily,
            automaticallyInstalls: false,
            notice: notice
        )
    }

    @Test func neverCheckedReadsNever() {
        #expect(state().lastCheckedText == "Never")
    }

    @Test func aCheckReadsAsItsDate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(state(lastChecked: date).lastCheckedText == date.formatted(
            date: .abbreviated,
            time: .shortened
        ))
    }

    @Test("Frequency and automatic install follow the automatic-check toggle", arguments: [
        (true, true, true),
        (true, false, false),
        (false, true, false),
        (false, false, false)
    ])
    func automaticOptions(_ isEnabled: Bool, _ automaticallyChecks: Bool, _ offered: Bool) {
        #expect(state(isEnabled: isEnabled, automaticallyChecks: automaticallyChecks)
            .offersAutomaticOptions == offered)
    }

    @Test func aDevelopmentBuildSaysUpdatesAreOffWhateverElseItCarries() {
        #expect(state(isEnabled: false, notice: "anything")
            .shownNotice == "Updates are off in development builds.")
    }

    @Test func anEnabledBuildShowsItsOwnNoticeOrNone() {
        #expect(state().shownNotice == nil)
        #expect(state(notice: "Kibble couldn't start checking for updates.").shownNotice
            == "Kibble couldn't start checking for updates.")
    }

    @Test func frequencyTitles() {
        #expect(UpdateFrequency.allCases.map(\.title) == ["At launch", "Every hour", "Every day"])
    }
}
