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
        #expect(NotifyControl.apply(.nothing, to: NotificationRule(), inherited: .builtIn, fallback: .banner)
            == NotificationRule(delivery: .off))
    }

    /// Review Focus 2: on a level that inherits Off, a choice also writes the
    /// fallback delivery so that it takes effect; Default undoes both.
    @Test func mentionsOnlyOnMeetChatsWritesADeliveryAndDefaultUndoesIt() {
        let chosen = NotifyControl.apply(
            .mentions,
            to: NotificationRule(),
            inherited: meetInherited,
            fallback: .banner
        )
        #expect(chosen == NotificationRule(delivery: .banner, notifyAbout: .mentions))
        #expect(NotifyControl.apply(nil, to: chosen, inherited: meetInherited, fallback: .banner)
            == NotificationRule())
    }

    /// Where the level does not inherit Nothing, Default leaves an explicit
    /// delivery alone: "Deliver as" has its own Default.
    @Test func defaultKeepsAnExplicitDeliveryWhereTheLevelInheritsSound() {
        let rule = NotificationRule(delivery: .banner, notifyAbout: .mentions)
        #expect(NotifyControl.apply(nil, to: rule, inherited: .builtIn, fallback: .banner)
            == NotificationRule(delivery: .banner))
    }

    @Test func choosingAChoiceOverAnOwnOffClearsTheOffAndKeepsOtherFields() {
        let muted = NotificationRule().muted()
        let chosen = NotifyControl.apply(.allMessages, to: muted, inherited: .builtIn, fallback: .banner)
        #expect(chosen == NotificationRule(
            showsUnread: false,
            countsInBadge: false,
            notifyAbout: .allMessages
        ))
    }

    @Test func defaultClearsNotifyAboutAndAnOwnOffOnly() {
        let rule = NotificationRule(delivery: .off, showsPreview: false, notifyAbout: .mentions)
        #expect(NotifyControl.apply(nil, to: rule, inherited: .builtIn, fallback: .banner)
            == NotificationRule(showsPreview: false))
    }

    /// Spec §4: the control shows Nothing exactly when the level resolves to
    /// Off. A `notifyAbout` of the level's own that cannot take effect -
    /// "Deliver as" set back to "Default (Off)" on Meet Chats, or a global Off
    /// under a section's Mentions only - selects Default, whose label reads
    /// Nothing, rather than a choice that is not happening.
    @Test func aChoiceThatCannotTakeEffectSelectsDefault() {
        let dormant = NotificationRule(notifyAbout: .mentions)
        #expect(NotifyControl.selected(dormant, inherited: meetInherited) == nil)
        #expect(NotifyControl.selected(dormant, inherited: .builtIn) == .mentions)
        let working = NotificationRule(delivery: .banner, notifyAbout: .mentions)
        #expect(NotifyControl.selected(working, inherited: meetInherited) == .mentions)
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
        #expect(NotifyControl.apply(nil, to: banner, inherited: meetInherited, fallback: .banner)
            == NotificationRule())
    }

    /// Fix round 1, Minor 1: a delivery a newer build wrote resolves as
    /// inherit, so a choice over it where the level inherits Off must write
    /// the fallback, or the pick would resolve straight back to Nothing.
    @Test func aChoiceOverAnUnknownDeliveryWhereTheLevelInheritsOffWritesTheFallback() {
        let unknown = NotificationRule(delivery: .unknown("x"))
        let chosen = NotifyControl.apply(.mentions, to: unknown, inherited: meetInherited, fallback: .banner)
        #expect(chosen == NotificationRule(delivery: .banner, notifyAbout: .mentions))
        #expect(NotifyControl.selected(chosen, inherited: meetInherited) == .mentions)
    }

    /// Fix round 1, Minor 4: when "Deliver as" is reachable, and whether it
    /// offers a Default (never Off - plan ruling 7).
    @Test func deliverAsAppearsOnlyWhereTheLevelNotifiesAndNeverOffersOff() {
        let globalNothing = NotificationRule.resolve([NotificationRule(delivery: .off)])
        #expect(NotifyControl.showsDelivery(rule: NotificationRule(), inherited: .builtIn))
        #expect(NotifyControl.offersDefaultDelivery(inherited: .builtIn))
        #expect(!NotifyControl.showsDelivery(rule: NotificationRule(), inherited: meetInherited))
        let meetMentions = NotificationRule(delivery: .banner, notifyAbout: .mentions)
        #expect(NotifyControl.showsDelivery(rule: meetMentions, inherited: meetInherited))
        #expect(!NotifyControl.offersDefaultDelivery(inherited: meetInherited))
        #expect(!NotifyControl.showsDelivery(rule: NotificationRule(), inherited: globalNothing))
        #expect(!NotifyControl.offersDefaultDelivery(inherited: globalNothing))
        #expect(NotifyControl.showsDelivery(
            rule: NotificationRule(delivery: .banner),
            inherited: globalNothing
        ))
    }

    @Test func theThreeChoicesHaveTheirTitles() {
        #expect(Display.title(of: NotifyChoice.allMessages) == "All messages")
        #expect(Display.title(of: NotifyChoice.mentions) == "Mentions only")
        #expect(Display.title(of: NotifyChoice.nothing) == "Nothing")
    }
}
