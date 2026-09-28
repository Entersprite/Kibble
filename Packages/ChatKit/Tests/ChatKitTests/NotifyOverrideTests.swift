import Foundation
import Testing
@testable import ChatKit

/// The owner's rule (2026-09-27), resolved in `NotificationRule.resolve`: a
/// level whose own record says All messages or Mentions only overrides an Off
/// inherited from any level above it, and delivers as the first audible
/// delivery below it (mentions spec §4, as amended).
struct NotifyOverrideTests {
    private let mentions = NotificationRule(notifyAbout: .mentions)

    /// Final review, Important 1, Scenario A: a section's Mentions only
    /// survives the global being set to Nothing afterwards.
    @Test func aSectionsMentionsOnlyOverridesAGlobalNothing() {
        let resolved = NotificationRule.resolve([mentions, NotificationRule(delivery: .off)])
        #expect(resolved.delivery == .bannerAndSound)
        #expect(resolved.notifyAbout == .mentions)
    }

    /// The first audible delivery below wins, not the built-in.
    @Test func mentionsOnlyOnMeetChatsDeliversAsTheGlobalDelivery() {
        let resolved = NotificationRule.resolve([
            mentions, NotificationRule.meetChatsPreset, NotificationRule(delivery: .banner)
        ])
        #expect(resolved.delivery == .banner)
        #expect(resolved.audibleDelivery == .banner)
    }

    @Test func aConversationsOwnNothingBeatsItsSectionsMentionsOnly() {
        let resolved = NotificationRule.resolve([NotificationRule(delivery: .off), mentions])
        #expect(resolved.delivery == .off)
        let muted = NotificationRule.resolve([NotificationRule().muted(), mentions])
        #expect(muted.delivery == .off)
    }

    @Test func aConversationsMentionsOnlyOverridesItsSectionsNothing() {
        let resolved = NotificationRule.resolve([
            mentions, NotificationRule(delivery: .off), NotificationRule(delivery: .banner)
        ])
        #expect(resolved.delivery == .banner)
        #expect(resolved.notifyAbout == .mentions)
    }

    @Test func anUnknownNotifyAboutNeverOverrides() {
        let resolved = NotificationRule.resolve([
            NotificationRule(notifyAbout: .unknown("x")), NotificationRule(delivery: .off)
        ])
        #expect(resolved.delivery == .off)
    }

    @Test func aLevelsOwnOffIsNothingWhateverItsNotifyAboutSays() {
        let resolved = NotificationRule.resolve([NotificationRule(delivery: .off, notifyAbout: .mentions)])
        #expect(resolved.delivery == .off)
    }

    @Test func theAudibleDeliverySkipsOffAndFallsBackToTheBuiltIn() {
        #expect(ResolvedRule.builtIn.audibleDelivery == .bannerAndSound)
        let offOverBanner = [NotificationRule(delivery: .off), NotificationRule(delivery: .banner)]
        #expect(NotificationRule.resolve(offOverBanner).audibleDelivery == .banner)
        #expect(NotificationRule.resolve([NotificationRule(delivery: .off)]).audibleDelivery
            == .bannerAndSound)
    }

    /// With nothing audible in the chain, an override takes the fallback's
    /// audible delivery, not the built-in - which is what an editor resolving
    /// `[rule]` below a flattened `inherited` relies on.
    @Test func anOverrideBelowAnOffFallbackTakesTheFallbacksAudibleDelivery() {
        let inherited = NotificationRule.resolve([
            NotificationRule.meetChatsPreset, NotificationRule(delivery: .notificationCenter)
        ])
        #expect(inherited.delivery == .off)
        #expect(NotificationRule.resolve([mentions], below: inherited).delivery == .notificationCenter)
        #expect(NotificationRule.resolve([NotificationRule()], below: inherited).delivery == .off)
    }

    /// `resolve(prefix, below: resolve(suffix))` is `resolve(prefix + suffix)`
    /// for every split of every chain of one to three levels - what makes an
    /// editor's `resolve([rule], below: inherited)` agree with
    /// `NotificationSettings.resolve(for:)`. Over two fallbacks: the built-in,
    /// and an Off one with an audible delivery of its own beneath it.
    @Test func resolutionComposes() {
        let records = [nil, Delivery.off, .banner].flatMap { delivery in
            [nil, NotifyAbout.mentions].map { NotificationRule(delivery: delivery, notifyAbout: $0) }
        }
        let chains = (1 ... 3).flatMap { length in
            (1 ..< length).reduce(records.map { [$0] }) { partial, _ in
                partial.flatMap { chain in records.map { chain + [$0] } }
            }
        }
        let silent = NotificationRule.resolve([
            NotificationRule(delivery: .off), NotificationRule(delivery: .notificationCenter)
        ])
        var checked = 0
        for fallback in [ResolvedRule.builtIn, silent] {
            for chain in chains {
                let whole = NotificationRule.resolve(chain, below: fallback)
                for split in 0 ... chain.count {
                    let below = NotificationRule.resolve(Array(chain[split...]), below: fallback)
                    #expect(NotificationRule.resolve(Array(chain[..<split]), below: below) == whole)
                    checked += 1
                }
            }
        }
        #expect(chains.count == 258)
        #expect(checked == 1968)
    }
}
