import ChatKit
import Foundation

/// Presence on screen: the other person in a one-to-one DM, and the sender
/// beside a message - never the local user, and only while the session is
/// live.
public extension Display {
    /// The presence worth drawing for `conversation`, or `nil` for nothing.
    ///
    /// - **A one-to-one DM with a person only.** A group has no one person to
    ///   show, and an app has no presence.
    /// - **Only while connected.** Presence is a claim about now. Offline,
    ///   the last poll's answer is a stale claim, so nothing is drawn.
    /// - **Only once the local user is known.** Before that, "the member who
    ///   is not me" may be me, and the local user's own presence is polled
    ///   too, so every DM row would show your own dot.
    /// - **Only a state this build can name.** `nil` ("nobody told us") and
    ///   `.unknown` both draw nothing, rather than a dot that means nothing.
    static func presence(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState
    ) -> Presence? {
        guard conversation.kind == .directMessage, let me,
              let other = conversation.members.first(where: { $0 != me })
        else { return nil }
        return presence(of: other, directory: directory, me: me, connection: connection)
    }

    /// The presence worth drawing beside `member`'s face - a message's
    /// sender - by the same rules: connected, a state this build can name,
    /// and never the local user, whose own presence is polled and stored but
    /// is not news to them. `nil` while `me` is unknown, for the same reason
    /// as above.
    static func presence(
        of member: Member.ID,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState
    ) -> Presence? {
        guard connection == .connected, let me, member != me,
              let presence = directory[member]?.presence,
              presenceLabel(presence) != nil
        else { return nil }
        return presence
    }

    /// The header's words for a presence, and the badge's accessibility label.
    static func presenceLabel(_ presence: Presence) -> String? {
        switch presence {
        case .active: "Active"
        case .inactive: "Away"
        case .doNotDisturb: "Do not disturb"
        case .unknown: nil
        }
    }
}
