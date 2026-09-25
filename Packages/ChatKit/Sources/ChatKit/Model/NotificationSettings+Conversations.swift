import Foundation

/// A conversation's own record: what Mute and Unmute write, and what the
/// conversation editor and the Conversations pane read (spec §2.5, §4).
public extension NotificationRule {
    /// Delivery Off, unread hidden, not counted - and every other field as it
    /// was.
    func muted() -> NotificationRule {
        var rule = self
        rule.delivery = .off
        rule.showsUnread = false
        rule.countsInBadge = false
        return rule
    }

    /// Clears exactly the three fields `muted()` writes, even one that was set
    /// by hand before muting (spec §2.5), and leaves the rest.
    func unmuted() -> NotificationRule {
        var rule = self
        rule.delivery = nil
        rule.showsUnread = nil
        rule.countsInBadge = nil
        return rule
    }
}

public extension NotificationSettings {
    /// Whether the conversation's **own** record says Off. Inherited Off - a
    /// silent section, the Meet preset - is not muted, so the menu never
    /// offers an Unmute that could change nothing.
    func isMuted(_ id: Conversation.ID) -> Bool {
        rule(for: .conversation(id))?.delivery == .off
    }

    /// What the conversation falls back to when its own record says nothing -
    /// its editor's "Default (…)" values.
    func inherited(byConversation conversation: Conversation) -> ResolvedRule {
        resolvedSection(SectionKey(kind: conversation.kind).ruleSection)
    }

    /// Conversations whose own record says something, in record order. An
    /// emptied record is not an override.
    var customizedConversations: [Conversation.ID] {
        records.compactMap { record in
            guard case let .conversation(id) = record.scope,
                  case let .rule(rule) = record.value,
                  !rule.isEmpty
            else { return nil }
            return id
        }
    }
}
