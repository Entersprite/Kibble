import Foundation
import Testing
@testable import DesignSystem

struct UpdateSettingsPaneTests {
    private func state(
        isEnabled: Bool = true,
        lastChecked: Date? = nil,
        frequency: UpdateFrequency = .daily,
        notice: String? = nil
    ) -> UpdateSettingsState {
        UpdateSettingsState(
            version: "2026.41.1",
            isEnabled: isEnabled,
            canCheck: true,
            lastChecked: lastChecked,
            checksAtLaunch: true,
            frequency: frequency,
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

    @Test("Automatic install is offered while the schedule runs", arguments: [
        (true, UpdateFrequency.daily, true),
        (true, .weekly, true),
        (true, .never, false),
        (false, .daily, false),
        (false, .never, false)
    ])
    func automaticInstall(_ isEnabled: Bool, _ frequency: UpdateFrequency, _ offered: Bool) {
        #expect(state(isEnabled: isEnabled, frequency: frequency).offersAutomaticInstall == offered)
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
        #expect(UpdateFrequency.allCases.map(\.title) == ["Never", "Every Hour", "Every Day", "Every Week"])
    }
}
