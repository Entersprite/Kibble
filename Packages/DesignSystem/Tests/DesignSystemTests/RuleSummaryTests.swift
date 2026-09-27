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

    @Test func mentionsOnlyFollowsTheDelivery() {
        let rule = NotificationRule(delivery: .banner, notifyAbout: .mentions)
        #expect(RuleSummary.describe(rule: rule, resolved: NotificationRule.resolve([rule]))
            == "Banner · Mentions only · Custom")
    }

    /// Final review, Minor 4: an Off level reads Off, never "Mentions only".
    /// The record says Off itself - a Mentions only below an inherited Off
    /// would override it and be audible (`NotificationRule.resolve`).
    @Test func anOffLevelNeverReadsMentionsOnly() {
        let rule = NotificationRule(delivery: .off, notifyAbout: .mentions)
        let resolved = NotificationRule.resolve([rule])
        #expect(resolved.delivery == .off)
        #expect(resolved.notifyAbout == .mentions)
        #expect(RuleSummary.describe(rule: rule, resolved: resolved) == "Off · Custom")
    }
}
