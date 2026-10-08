import ChatKit
import Foundation

/// A person's status on screen: the emoji beside a DM row's name, and the
/// words in the DM's header - by `Display.presence`'s rules, plus expiry.
public extension Display {
    /// The status worth drawing for `member`, or `nil` for nothing.
    ///
    /// The same rules as presence - connected, the local user known, and
    /// never the local user - plus two of its own: something to show, and
    /// not past `expiresAt`. The expiry is checked against `now` at render
    /// time rather than trusted to the next poll, so a status that ran out
    /// at 17:00 is not still drawn at 17:01.
    static func status(
        of member: Member.ID,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> MemberStatus? {
        guard connection == .connected, let me, member != me,
              let status = directory[member]?.status, !status.isEmpty
        else { return nil }
        if let expiresAt = status.expiresAt, expiresAt <= now {
            return nil
        }
        return status
    }

    /// A one-to-one DM's other person's status; nothing for any other kind.
    static func status(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState,
        now: Date
    ) -> MemberStatus? {
        guard conversation.kind == .directMessage, let me,
              let other = conversation.members.first(where: { $0 != me })
        else { return nil }
        return status(of: other, directory: directory, me: me, connection: connection, now: now)
    }

    /// "🌴 On vacation": the emoji, or a custom emoji's shortcode, then the
    /// text. The tooltip and the header both read this.
    static func statusSummary(_ status: MemberStatus) -> String {
        [status.emoji ?? status.customEmojiShortcode, status.text]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    /// The DM header's subtitle: "Away · In a meeting until 15:00 · 🌴 On
    /// vacation", any part alone, or `nil` for nothing. `calendar` is already
    /// in words (`calendarSummary`).
    static func headerSubtitle(presence: Presence?, calendar: String? = nil, status: MemberStatus?) -> String? {
        let parts = [presence.flatMap(presenceLabel), calendar, status.map(statusSummary)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
