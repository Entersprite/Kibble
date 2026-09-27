import ChatKit
import Testing
@testable import DesignSystem

struct NotifyControlTests {
    private let meetInherited = NotificationRule.resolve([NotificationRule.meetChatsPreset])

    @Test func ownChoiceReadsNothingFromOffAndDefaultFromEmpty() {
        #expect(NotifyControl.own(NotificationRule(delivery: .off, notifyAbout: .mentions)) == .nothing)
        #expect(NotifyControl.own(NotificationRule(notifyAbout: .mentions)) == .mentions)
        #expect(NotifyControl.own(NotificationRule()) == nil)
    }

    @Test func theShownValueIsNothingExactlyWhenTheResolvedDeliveryIsOff() {
        #expect(NotifyControl.shown(meetInherited) == .nothing)
        var mentions = ResolvedRule.builtIn
        mentions.notifyAbout = .mentions
        #expect(NotifyControl.shown(mentions) == .mentions)
        #expect(NotifyControl.shown(.builtIn) == .allMessages)
    }

    @Test func choosingNothingWritesOff() {
        #expect(NotifyControl.apply(.nothing, to: NotificationRule(), inherited: .builtIn)
            == NotificationRule(delivery: .off))
    }

    /// The owner's rule (2026-09-27): a choice never writes a delivery. On a
    /// level that inherits Off it takes effect at resolve time, and Default
    /// undoes it.
    @Test func mentionsOnlyOnMeetChatsWritesNoDeliveryAndDefaultUndoesIt() {
        let chosen = NotifyControl.apply(.mentions, to: NotificationRule(), inherited: meetInherited)
        #expect(chosen == NotificationRule(notifyAbout: .mentions))
        #expect(NotificationRule.resolve([chosen], below: meetInherited).delivery == .bannerAndSound)
        let reset = NotifyControl.apply(nil, to: chosen, inherited: meetInherited)
        #expect(reset == NotificationRule())
        #expect(NotificationRule.resolve([reset], below: meetInherited).delivery == .off)
    }

    /// Where the level does not inherit Nothing, Default leaves an explicit
    /// delivery alone: "Deliver as" has its own Default.
    @Test func defaultKeepsAnExplicitDeliveryWhereTheLevelInheritsSound() {
        let rule = NotificationRule(delivery: .banner, notifyAbout: .mentions)
        #expect(NotifyControl
            .apply(nil, to: rule, inherited: .builtIn) == NotificationRule(delivery: .banner))
    }

    @Test func choosingAChoiceOverAnOwnOffClearsTheOffAndKeepsOtherFields() {
        let muted = NotificationRule().muted()
        let chosen = NotifyControl.apply(.allMessages, to: muted, inherited: .builtIn)
        #expect(chosen == NotificationRule(
            showsUnread: false,
            countsInBadge: false,
            notifyAbout: .allMessages
        ))
    }

    @Test func defaultClearsNotifyAboutAndAnOwnOffOnly() {
        let rule = NotificationRule(delivery: .off, showsPreview: false, notifyAbout: .mentions)
        #expect(NotifyControl
            .apply(nil, to: rule, inherited: .builtIn) == NotificationRule(showsPreview: false))
    }

    /// Spec §4: the control shows what the level does. Under an inherited
    /// Nothing a choice of the level's own now takes effect, so it is
    /// selected; an unknown one does not, so Default (Nothing) is.
    @Test func underAnInheritedNothingTheSelectionIsWhatTheLevelDoes() {
        #expect(NotifyControl.selected(NotificationRule(notifyAbout: .mentions), inherited: meetInherited)
            == .mentions)
        #expect(NotifyControl.selected(NotificationRule(notifyAbout: .unknown("x")), inherited: meetInherited)
            == nil)
        #expect(NotifyControl.selected(NotificationRule(), inherited: meetInherited) == nil)
        #expect(NotifyControl
            .selected(NotificationRule(delivery: .off), inherited: meetInherited) == .nothing)
    }

    /// Fix round 1, Important 1: on a level that inherits Nothing, an own
    /// audible delivery with no `notifyAbout` notifies, so the control says
    /// what it does rather than "Default (Nothing)" - and Default from there
    /// returns the level to Nothing.
    @Test func anOwnDeliveryUnderAnInheritedNothingShowsWhatItNotifies() {
        let banner = NotificationRule(delivery: .banner)
        #expect(NotifyControl.selected(banner, inherited: meetInherited) == .allMessages)
        // Elsewhere, Default stays Default: nothing of its own selects nil.
        #expect(NotifyControl.selected(NotificationRule(), inherited: .builtIn) == nil)
        #expect(NotifyControl.apply(nil, to: banner, inherited: meetInherited) == NotificationRule())
    }

    /// Fix round 1, Minor 1: a delivery a newer build wrote resolves as
    /// inherit. A choice over one where the level inherits Off clears it, as
    /// round 1's fallback replaced it, and writes no delivery of its own.
    @Test func aChoiceOverAnUnknownDeliveryWhereTheLevelInheritsOffClearsIt() {
        let unknown = NotificationRule(delivery: .unknown("x"))
        let chosen = NotifyControl.apply(.mentions, to: unknown, inherited: meetInherited)
        #expect(chosen == NotificationRule(notifyAbout: .mentions))
        #expect(NotifyControl.selected(chosen, inherited: meetInherited) == .mentions)
        // Elsewhere it is left alone, as `nil` would be.
        #expect(NotifyControl.apply(.mentions, to: unknown, inherited: .builtIn)
            == NotificationRule(delivery: .unknown("x"), notifyAbout: .mentions))
    }

    /// Fix round 1, Minor 4: when "Deliver as" is reachable (never Off -
    /// plan ruling 7).
    @Test func deliverAsAppearsOnlyWhereTheLevelNotifies() {
        let globalNothing = NotificationRule.resolve([NotificationRule(delivery: .off)])
        #expect(NotifyControl.showsDelivery(rule: NotificationRule(), inherited: .builtIn))
        #expect(!NotifyControl.showsDelivery(rule: NotificationRule(), inherited: meetInherited))
        #expect(NotifyControl.showsDelivery(
            rule: NotificationRule(notifyAbout: .mentions),
            inherited: meetInherited
        ))
        #expect(!NotifyControl.showsDelivery(rule: NotificationRule(), inherited: globalNothing))
        #expect(NotifyControl.showsDelivery(
            rule: NotificationRule(delivery: .banner),
            inherited: globalNothing
        ))
    }

    /// The "Default (…)" delivery is what the level resolves to without a
    /// delivery of its own, and it is offered exactly when that is not Off.
    @Test func theDefaultDeliveryIsWhatTheLevelResolvesToWithoutItsOwn() {
        let meetUnderBanner = NotificationRule.resolve([
            NotificationRule.meetChatsPreset, NotificationRule(delivery: .banner)
        ])
        let mentions = NotificationRule(notifyAbout: .mentions)
        #expect(NotifyControl.defaultDelivery(rule: mentions, inherited: meetUnderBanner) == .banner)
        #expect(NotifyControl.offersDefaultDelivery(rule: mentions, inherited: meetUnderBanner))
        #expect(NotifyControl.defaultDelivery(rule: NotificationRule(), inherited: meetUnderBanner) == .off)
        #expect(!NotifyControl.offersDefaultDelivery(rule: NotificationRule(), inherited: meetUnderBanner))
        let banner = NotificationRule(delivery: .banner)
        #expect(NotifyControl.defaultDelivery(rule: banner, inherited: meetUnderBanner) == .off)
        #expect(!NotifyControl.offersDefaultDelivery(rule: banner, inherited: meetUnderBanner))
        #expect(NotifyControl.defaultDelivery(rule: banner, inherited: .builtIn) == .bannerAndSound)
        #expect(NotifyControl.offersDefaultDelivery(rule: banner, inherited: .builtIn))
    }

    @Test func theThreeChoicesHaveTheirTitles() {
        #expect(Display.title(of: NotifyChoice.allMessages) == "All messages")
        #expect(Display.title(of: NotifyChoice.mentions) == "Mentions only")
        #expect(Display.title(of: NotifyChoice.nothing) == "Nothing")
    }
}
