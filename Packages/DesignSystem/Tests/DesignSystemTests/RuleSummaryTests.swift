import ChatKit
import Testing
@testable import DesignSystem

struct RuleSummaryTests {
    @Test func anUntouchedSectionShowsWhatItResolvesTo() {
        #expect(RuleSummary.describe(rule: NotificationRule(), resolved: .builtIn) == "Banner and sound")
    }

    @Test func meetChatsPresetReadsOffWithUnreadHidden() {
        let resolved = NotificationRule.resolve([NotificationRule.meetChatsPreset])
        #expect(RuleSummary.describe(rule: NotificationRule(), resolved: resolved) == "Off · Unread hidden")
    }

    @Test func aSectionWithItsOwnRecordSaysCustom() {
        let rule = NotificationRule(delivery: .banner)
        #expect(RuleSummary
            .describe(rule: rule, resolved: NotificationRule.resolve([rule])) == "Banner · Custom")
    }
}
