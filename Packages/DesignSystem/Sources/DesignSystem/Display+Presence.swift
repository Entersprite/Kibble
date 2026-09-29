import ChatKit
import Foundation

/// Presence on screen: the other person in a one-to-one DM, and only while
/// the session is live.
public extension Display {
    /// The presence worth drawing for `conversation`, or `nil` for nothing.
    ///
    /// - **A one-to-one DM with a person only.** A group has no one person to
    ///   show, and an app has no presence.
    /// - **Only while connected.** Presence is a claim about now. Offline,
    ///   the last poll's answer is a stale claim, so nothing is drawn.
    /// - **Only a state this build can name.** `nil` ("nobody told us") and
    ///   `.unknown` both draw nothing, rather than a dot that means nothing.
    static func presence(
        of conversation: Conversation,
        directory: [Member.ID: Member],
        me: Member.ID?,
        connection: ConnectionState
    ) -> Presence? {
        guard conversation.kind == .directMessage, connection == .connected,
              let other = conversation.members.first(where: { $0 != me }),
              let presence = directory[other]?.presence,
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
