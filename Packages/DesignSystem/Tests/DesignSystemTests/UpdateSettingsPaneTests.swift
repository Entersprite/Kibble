import Foundation
import Testing
@testable import DesignSystem

struct UpdateSettingsPaneTests {
    private func state(
        isEnabled: Bool = true,
        lastChecked: Date? = nil,
        checksAtLaunch: Bool = true,
        frequency: UpdateFrequency = .daily,
        notice: String? = nil
    ) -> UpdateSettingsState {
        UpdateSettingsState(
            version: "2026.41.1",
            isEnabled: isEnabled,
            canCheck: true,
            lastChecked: lastChecked,
            checksAtLaunch: checksAtLaunch,
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

    @Test("Automatic install is offered while Kibble checks on its own", arguments: [
        (true, true, UpdateFrequency.daily, true),
        (true, true, .never, true),
        (true, false, .weekly, true),
        (true, false, .never, false),
        (false, true, .daily, false),
        (false, false, .never, false)
    ])
    func automaticInstall(
        _ isEnabled: Bool,
        _ atLaunch: Bool,
        _ frequency: UpdateFrequency,
        _ offered: Bool
    ) {
        #expect(state(isEnabled: isEnabled, checksAtLaunch: atLaunch, frequency: frequency)
            .offersAutomaticInstall == offered)
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
