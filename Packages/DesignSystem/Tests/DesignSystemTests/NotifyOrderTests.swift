import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Final review, Important 1: the "Notify about" control's outcome must not
/// depend on the order of the user's edits. Each step goes through
/// `NotifyControl.apply` exactly as the pane's editors call it, and the
/// outcome is read back through `NotificationSettings`, the resolution the
/// policy uses.
struct NotifyOrderTests {
    private enum Step {
        case global(NotifyChoice)
        case globalDelivery(Delivery)
        case section(SectionKey, NotifyChoice?)
    }

    private func run(_ steps: [Step]) -> NotificationSettings {
        var settings = NotificationSettings()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for step in steps {
            switch step {
            case let .global(choice):
                let rule = settings.rule(for: .global) ?? NotificationRule()
                settings.setRule(
                    NotifyControl.apply(choice, to: rule, inherited: .builtIn),
                    for: .global, at: date, by: "d"
                )
            case let .globalDelivery(delivery):
                var rule = settings.rule(for: .global) ?? NotificationRule()
                rule.delivery = delivery
                settings.setRule(rule, for: .global, at: date, by: "d")
            case let .section(section, choice):
                let rule = settings.rule(for: .section(section)) ?? NotificationRule()
                settings.setRule(
                    NotifyControl.apply(choice, to: rule, inherited: settings.inherited(bySection: section)),
                    for: .section(section), at: date, by: "d"
                )
            }
        }
        return settings
    }

    /// Scenario A: the section's Mentions only survives a later global
    /// Nothing, and the editor shows it rather than "Default (Nothing)".
    @Test func aSectionsMentionsOnlyAndAGlobalNothingAgreeInEitherOrder() {
        let sectionFirst = run([.global(.allMessages), .section(.spaces, .mentions), .global(.nothing)])
        let globalFirst = run([.global(.allMessages), .global(.nothing), .section(.spaces, .mentions)])
        for settings in [sectionFirst, globalFirst] {
            let resolved = settings.resolvedSection(.spaces)
            #expect(resolved.delivery == .bannerAndSound)
            #expect(resolved.notifyAbout == .mentions)
            #expect(settings.rule(for: .section(.spaces)) == NotificationRule(notifyAbout: .mentions))
            #expect(NotifyControl.selected(
                NotificationRule(notifyAbout: .mentions),
                inherited: settings.inherited(bySection: .spaces)
            ) == .mentions)
        }
        #expect(sectionFirst.resolvedSection(.spaces) == globalFirst.resolvedSection(.spaces))
    }

    /// Scenario B, in both orders of the section's choice and the global's
    /// change; then Default leaves the section with no delivery of its own.
    @Test func aSectionsMentionsOnlyAndAGlobalBannerAgreeInEitherOrderAndDefaultLeavesNothing() {
        let sectionFirst = run([
            .global(.nothing), .section(.spaces, .mentions),
            .global(.allMessages), .globalDelivery(.banner)
        ])
        let globalFirst = run([
            .global(.nothing), .global(.allMessages), .globalDelivery(.banner),
            .section(.spaces, .mentions)
        ])
        for settings in [sectionFirst, globalFirst] {
            #expect(settings.resolvedSection(.spaces).delivery == .banner)
            #expect(settings.resolvedSection(.spaces).notifyAbout == .mentions)
        }
        #expect(sectionFirst.resolvedSection(.spaces) == globalFirst.resolvedSection(.spaces))
        let reset = run([
            .global(.nothing), .section(.spaces, .mentions),
            .global(.allMessages), .globalDelivery(.banner), .section(.spaces, nil)
        ])
        #expect(reset.rule(for: .section(.spaces)) == NotificationRule())
        #expect(reset.resolvedSection(.spaces).delivery == .banner)
        #expect(reset.resolvedSection(.spaces).notifyAbout == .allMessages)
    }

    /// Meet Chats: Mentions only then Default returns the section to `{}`,
    /// and so to its preset's Nothing.
    @Test func meetChatsMentionsOnlyThenDefaultReturnsToThePreset() {
        let chosen = run([.section(.meetChats, .mentions)])
        #expect(chosen.rule(for: .section(.meetChats)) == NotificationRule(notifyAbout: .mentions))
        #expect(chosen.resolvedSection(.meetChats).delivery == .bannerAndSound)
        let reset = run([.section(.meetChats, .mentions), .section(.meetChats, nil)])
        #expect(reset.rule(for: .section(.meetChats)) == NotificationRule())
        #expect(reset.resolvedSection(.meetChats).delivery == .off)
    }
}
