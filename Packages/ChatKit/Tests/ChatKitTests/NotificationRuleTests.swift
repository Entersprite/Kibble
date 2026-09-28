import Foundation
import Testing
@testable import ChatKit

struct NotificationRuleTests {
    // MARK: - Resolution

    @Test func eachFieldInheritsIndependently() {
        let resolved = NotificationRule.resolve([
            NotificationRule(delivery: .banner),
            NotificationRule(countsInBadge: false),
            NotificationRule(showsPreview: false)
        ])
        #expect(resolved.delivery == .banner)
        #expect(resolved.countsInBadge == false)
        #expect(resolved.showsPreview == false)
        #expect(resolved.showsUnread == true)
        #expect(resolved.readReceipts == true)
    }

    @Test func theMostSpecificValueWins() {
        let resolved = NotificationRule.resolve([
            NotificationRule(delivery: .off),
            NotificationRule(delivery: .banner)
        ])
        #expect(resolved.delivery == .off)
    }

    /// A newer build's delivery value must fall through, never be guessed at.
    @Test func anUnknownDeliveryIsSkippedAsIfInherited() {
        let resolved = NotificationRule.resolve([
            NotificationRule(delivery: .unknown("timeSensitive")),
            NotificationRule(delivery: .notificationCenter)
        ])
        #expect(resolved.delivery == .notificationCenter)
    }

    @Test func anEmptyChainIsTheBuiltInDefault() {
        #expect(NotificationRule.resolve([]) == .builtIn)
        #expect(ResolvedRule.builtIn.delivery == .bannerAndSound)
    }

    @Test func anEmptyRuleIsEmptyAndAnyFieldMakesItNot() {
        #expect(NotificationRule().isEmpty)
        #expect(!NotificationRule(readReceipts: false).isEmpty)
    }

    @Test func notifyAboutInheritsFieldByFieldAndAnUnknownValueIsSkipped() {
        let section = NotificationRule(notifyAbout: .mentions)
        let conversation = NotificationRule(delivery: .banner, notifyAbout: .unknown("threads"))
        #expect(NotificationRule.resolve([conversation, section]).notifyAbout == .mentions)
        #expect(NotificationRule.resolve([conversation]).notifyAbout == .allMessages)
        #expect(ResolvedRule.builtIn.notifyAbout == .allMessages)
    }

    @Test func aRuleWithOnlyNotifyAboutIsNotEmpty() {
        #expect(!NotificationRule(notifyAbout: .mentions).isEmpty)
    }

    // MARK: - Sections

    @Test func everyKindHasTheSectionItIsListedUnder() {
        #expect(SectionKey(kind: .directMessage) == .directMessages)
        #expect(SectionKey(kind: .groupDirectMessage) == .groupChats)
        #expect(SectionKey(kind: .space) == .spaces)
        #expect(SectionKey(kind: .appDirectMessage) == .apps)
        #expect(SectionKey(kind: .meetChat) == .meetChats)
        #expect(SectionKey(kind: .unknown("")) == .other)
        #expect(SectionKey(kind: .unknown("attributeCheckerGroupType12")) ==
            .unknown("attributeCheckerGroupType12"))
    }

    /// Unrecognised group types get their own sidebar heading but share
    /// Other's rule - there is no way to set a rule for a type nobody can name.
    @Test func unrecognisedTypesUseTheOtherRule() {
        #expect(SectionKey.unknown("attributeCheckerGroupType12").ruleSection == .other)
        #expect(SectionKey.spaces.ruleSection == .spaces)
    }

    @Test func ruleSectionsAreInSidebarOrder() {
        #expect(SectionKey.ruleSections == [.directMessages, .groupChats, .spaces, .apps, .meetChats, .other])
    }
}
