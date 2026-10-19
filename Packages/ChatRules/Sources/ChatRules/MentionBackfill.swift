import ChatKit
import Foundation

/// What the Mentions pane is told about the backfill (the mentions-list spec
/// §2): whether a run is going, and how many conversations the last finished
/// run could not fetch.
public struct MentionBackfillStatus: Sendable, Equatable {
    public var running: Bool
    public var failedConversations: Int

    public init(running: Bool = false, failedConversations: Int = 0) {
        self.running = running
        self.failedConversations = failedConversations
    }
}

/// Which conversations a backfill fetches. Pure, so that the window's edges
/// are tests. The runner is `SyncEngine+MentionBackfill.swift`.
///
/// Google has no mentions query (`findings.md` §44, the Mentions spike).
/// Chat on the web fetches candidate conversations and filters them itself,
/// and this does the same with the one call this client has measured: the
/// newest page (spec §2, "why the newest page").
public enum MentionBackfill {
    /// Thirty days, in seconds.
    public static let window: TimeInterval = 2_592_000

    /// Chat on the web ran its fetches two to four at a time (§44.1).
    public static let maxInFlight = 3

    /// Not Meet chats (§44.4), active within `window` of `now`, newest first.
    ///
    /// Exactly `window` old is in, and one second older is out. A
    /// `lastActivity` after `now` (clock skew) is in. `nil` - "never, or not
    /// known yet" - is out. Ties break on the id, so a run's order never
    /// wobbles.
    public static func candidates(in conversations: [Conversation], now: Date) -> [Conversation.ID] {
        let oldest = now.addingTimeInterval(-window)
        return conversations
            .filter { conversation in
                guard conversation.kind != .meetChat, let activity = conversation.lastActivity else {
                    return false
                }
                return activity >= oldest
            }
            .sorted { left, right in
                // Both are non-nil: the filter kept only those.
                if left.lastActivity != right.lastActivity {
                    return (left.lastActivity ?? oldest) > (right.lastActivity ?? oldest)
                }
                return left.id.rawValue < right.id.rawValue
            }
            .map(\.id)
    }
}
