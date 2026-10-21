import ChatKit
import Testing
@testable import DesignSystem

struct RuleSummaryTests {
    @Test func anUntouchedSectionShowsWhatItResolvesTo() {
        #expect(RuleSummary.describe(rule: NotificationRule(), resolved: .builtIn) == "Banner and Sound")
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
            == "Banner · Mentions Only · Custom")
    }

    /// An Off level reads Off, never "Mentions Only".
    /// The record says Off itself - a Mentions Only below an inherited Off
    /// would override it and be audible (`NotificationRule.resolve`).
    @Test func anOffLevelNeverReadsMentionsOnly() {
        let rule = NotificationRule(delivery: .off, notifyAbout: .mentions)
        let resolved = NotificationRule.resolve([rule])
        #expect(resolved.delivery == .off)
        #expect(resolved.notifyAbout == .mentions)
        #expect(RuleSummary.describe(rule: rule, resolved: resolved) == "Off · Custom")
    }
}
