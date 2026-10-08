import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The status menu's rows (set-your-status spec §5.1).
struct StatusMenuModelTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday 7 October 2026, 14:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_383_400)

    private func model(_ availability: Availability?, _ status: MemberStatus? = nil) -> StatusMenuModel {
        StatusMenuModel(
            availability: availability, status: status, now: now, calendar: utc,
            time: { _ in "15:00" }, day: { _ in "Fri 9 Oct" }
        )
    }

    @Test func theCurrentSettingIsChecked() {
        #expect(model(.automatic).isAutomatic)
        #expect(!model(.automatic).isAway)
        #expect(model(.away).isAway)
        #expect(!model(.away).isAutomatic)
        #expect(!model(nil).isAutomatic)
        #expect(!model(.unknown("x")).isAway)
    }

    @Test func doNotDisturbSaysUntilWhenWhileOn() {
        let on = model(.doNotDisturb(until: now.addingTimeInterval(600)))
        #expect(on.isDoNotDisturb)
        #expect(!on.isAutomatic)
        #expect(on.doNotDisturbTitle == "Do not disturb until 15:00")
    }

    /// Ruling 4: nothing pushes its end, so an ended one is Automatic again.
    @Test func doNotDisturbThatHasEndedIsAutomatic() {
        let ended = model(.doNotDisturb(until: now.addingTimeInterval(-1)))
        #expect(!ended.isDoNotDisturb)
        #expect(ended.isAutomatic)
        #expect(ended.doNotDisturbTitle == "Do not disturb")
    }

    @Test func doNotDisturbOffersItsDurations() {
        let choices = model(.automatic).doNotDisturbChoices
        #expect(choices.map(\.title)
            == [
                "For 30 minutes",
                "For 1 hour",
                "For 2 hours",
                "For 4 hours",
                "For 8 hours",
                "Until tomorrow"
            ])
        #expect(choices.first?.until == now.addingTimeInterval(1800))
        #expect(choices.last?.until == Date(timeIntervalSince1970: 1_791_450_000))
    }

    @Test func aStatusIsShownWithItsUntil() {
        let today = model(.automatic, MemberStatus(
            emoji: "🏠", text: "Working remotely", expiresAt: now.addingTimeInterval(3600)
        ))
        #expect(today.statusLine == "🏠 Working remotely · until 15:00")
        let later = model(.automatic, MemberStatus(text: "Away", expiresAt: now.addingTimeInterval(259_200)))
        #expect(later.statusLine == "Away · until Fri 9 Oct")
        #expect(model(.automatic, MemberStatus(text: "Heads down")).statusLine == "Heads down")
    }

    @Test func withNoStatusThereIsNoStatusLineAndNoClear() {
        #expect(model(.automatic).statusLine == nil)
        #expect(model(.automatic, MemberStatus()).statusLine == nil)
    }

    /// Ruling 8: the footer redraws when Do not disturb ends.
    @Test func theFooterAlsoRedrawsWhenDoNotDisturbEnds() {
        let end = now.addingTimeInterval(600)
        #expect(Display.ownRedrawDates(for: nil, availability: .doNotDisturb(until: end), now: now) == [end])
        #expect(Display.ownRedrawDates(for: nil, availability: .doNotDisturb(until: now), now: now).isEmpty)
        #expect(Display.ownRedrawDates(for: nil, availability: .away, now: now).isEmpty)
    }
}
