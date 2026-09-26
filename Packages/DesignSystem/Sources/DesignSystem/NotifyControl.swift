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

    /// What a level's editor selects: `own(_:)`, except that a choice which
    /// cannot take effect - the level still resolves to Off, say after
    /// "Deliver as" went back to "Default (Off)" on Meet Chats - selects
    /// Default, whose label then reads Nothing. Spec §4 shows Nothing exactly
    /// when the level resolves to Off; showing "Mentions only" there would
    /// name a choice that is not happening. Choosing it again then writes
    /// `apply`'s fallback delivery, as on any level that inherits Off.
    public static func selected(_ rule: NotificationRule, inherited: ResolvedRule) -> NotifyChoice? {
        let choice = own(rule)
        if choice != .nothing, shown(NotificationRule.resolve([rule], below: inherited)) == .nothing {
            return nil
        }
        return choice
    }

    /// `fallback` is ruling 5's delivery: written when a choice would
    /// otherwise stay silent because the level inherits Off. Default clears
    /// `notifyAbout` and an own Off - and, where the level inherits Nothing,
    /// any delivery of its own, which on such a level only this control can
    /// have written. Elsewhere an explicit delivery stays: "Deliver as" has
    /// its own Default.
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
            if changed.delivery == nil, inherited.delivery == .off {
                changed.delivery = fallback
            }
        }
        return changed
    }
}
