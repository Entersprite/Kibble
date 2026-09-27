import ChatKit

/// What the "Notify about" control offers. Nothing is not a stored value: it
/// is delivery Off (mentions spec §4).
public enum NotifyChoice: Hashable, Sendable {
    case allMessages
    case mentions
    case nothing

    /// In the order a menu shows them.
    public static let choices: [NotifyChoice] = [.allMessages, .mentions, .nothing]
}

/// The one visible "Notify about" control over two stored fields (mentions
/// spec §4): Nothing is delivery Off; All messages and Mentions only are
/// `notifyAbout`. Pure, so every mapping is a test.
public enum NotifyControl {
    /// The level's own choice, `nil` for Default. An own Off is Nothing,
    /// whatever `notifyAbout` says; a value a newer build wrote is Default.
    public static func own(_ rule: NotificationRule) -> NotifyChoice? {
        if rule.delivery == .off {
            return .nothing
        }
        switch rule.notifyAbout {
        case .allMessages?: return .allMessages
        case .mentions?: return .mentions
        case .unknown?, nil: return nil
        }
    }

    /// What a level resolves to: Nothing exactly when its delivery is Off.
    public static func shown(_ resolved: ResolvedRule) -> NotifyChoice {
        if resolved.delivery == .off {
            return .nothing
        }
        return resolved.notifyAbout == .mentions ? .mentions : .allMessages
    }

    /// What a level's editor selects. Where the level inherits Nothing,
    /// Default *means* Nothing, so Default is selected exactly when the level
    /// is silent, and otherwise what it actually does - Meet Chats with only
    /// `{delivery: banner}` of its own shows All messages, not "Default
    /// (Nothing)" beside a visible "Deliver as: Banner", and a `notifyAbout`
    /// a newer build wrote, which never overrides, shows Default (spec §4:
    /// Nothing exactly when the level resolves to Off). An own All messages
    /// or Mentions only always takes effect now, so it selects itself.
    /// Elsewhere it is `own(_:)`.
    public static func selected(_ rule: NotificationRule, inherited: ResolvedRule) -> NotifyChoice? {
        let choice = own(rule)
        guard choice != .nothing, inherited.delivery == .off else { return choice }
        let resolved = shown(NotificationRule.resolve([rule], below: inherited))
        return resolved == .nothing ? nil : resolved
    }

    /// Whether a level's editor shows "Deliver as": hidden while the level
    /// resolves to Nothing (spec §4).
    public static func showsDelivery(rule: NotificationRule, inherited: ResolvedRule) -> Bool {
        shown(NotificationRule.resolve([rule], below: inherited)) != .nothing
    }

    /// The "Default (…)" delivery: what the level resolves to without a
    /// delivery of its own. Not `inherited.delivery` - on a level whose own
    /// All messages or Mentions only overrides an inherited Off, that is Off
    /// while the level delivers as the first audible delivery below it
    /// (`NotificationRule.resolve`).
    public static func defaultDelivery(rule: NotificationRule, inherited: ResolvedRule) -> Delivery {
        var own = rule
        own.delivery = nil
        return NotificationRule.resolve([own], below: inherited).delivery
    }

    /// Whether "Deliver as" offers a "Default (…)" item: exactly when that
    /// Default is not Off, since Off is reached only through Nothing (plan
    /// ruling 7, spec §4).
    public static func offersDefaultDelivery(rule: NotificationRule, inherited: ResolvedRule) -> Bool {
        defaultDelivery(rule: rule, inherited: inherited) != .off
    }

    /// A choice writes `notifyAbout` and **never a delivery**: on a level that
    /// inherits Off it takes effect at resolve time, where a lower level's
    /// choice overrides a higher level's Nothing (the owner's rule,
    /// 2026-09-27; `NotificationRule.resolve`). Writing a delivery here made
    /// the outcome depend on the order of edits (final review, Important 1).
    /// A choice clears an own Off, and - where the level inherits Off - an
    /// own delivery a newer build wrote, which round 1's fallback replaced.
    /// Default clears `notifyAbout` and an own Off - and, where the level
    /// inherits Nothing, any delivery of its own, so that Default means
    /// inherit, which is Nothing. Elsewhere an explicit delivery stays:
    /// "Deliver as" has its own Default.
    public static func apply(
        _ choice: NotifyChoice?, to rule: NotificationRule, inherited: ResolvedRule
    ) -> NotificationRule {
        var changed = rule
        switch choice {
        case nil:
            changed.notifyAbout = nil
            if changed.delivery == .off || inherited.delivery == .off {
                changed.delivery = nil
            }
        case .nothing?:
            changed.delivery = .off
        case .allMessages?, .mentions?:
            changed.notifyAbout = choice == .mentions ? .mentions : .allMessages
            if changed.delivery == .off || (isUnknown(changed.delivery) && inherited.delivery == .off) {
                changed.delivery = nil
            }
        }
        return changed
    }

    /// `Delivery.isKnown` is internal to ChatKit, and this is the only reader
    /// outside it that needs the distinction.
    private static func isUnknown(_ delivery: Delivery?) -> Bool {
        if case .unknown? = delivery {
            return true
        }
        return false
    }
}
