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
    /// left with no audible delivery shows Default rather than a choice that
    /// is not happening (spec §4: Nothing exactly when the level resolves to
    /// Off). Elsewhere it is `own(_:)`.
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

    /// Whether "Deliver as" offers a "Default (…)" item. Not where the level
    /// inherits Off: that Default would be Off, and Off is reached only
    /// through Nothing (plan ruling 7, spec §4).
    public static func offersDefaultDelivery(inherited: ResolvedRule) -> Bool {
        inherited.delivery != .off
    }

    /// `fallback` is ruling 5's delivery: written when a choice would
    /// otherwise stay silent because the level inherits Off. Default clears
    /// `notifyAbout` and an own Off - and, where the level inherits Nothing,
    /// any delivery of its own, which on such a level only this control can
    /// have written. Elsewhere an explicit delivery stays: "Deliver as" has
    /// its own Default. A delivery a newer build wrote counts as none, since
    /// resolution skips it: a choice over one on a level that inherits Off
    /// writes the fallback too, or it would resolve straight back to Off.
    public static func apply(
        _ choice: NotifyChoice?, to rule: NotificationRule, inherited: ResolvedRule, fallback: Delivery
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
            if changed.delivery == .off {
                changed.delivery = nil
            }
            if !isKnown(changed.delivery), inherited.delivery == .off {
                changed.delivery = fallback
            }
        }
        return changed
    }

    /// `Delivery.isKnown` is internal to ChatKit, and this is the only reader
    /// outside it that needs the distinction.
    private static func isKnown(_ delivery: Delivery?) -> Bool {
        switch delivery {
        case nil, .unknown?: false
        case .off?, .notificationCenter?, .banner?, .bannerAndSound?: true
        }
    }
}
