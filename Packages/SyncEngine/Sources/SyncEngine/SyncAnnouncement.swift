import ChatKit
import Foundation

/// What `SyncEngine.announcements` reports: the two notification-relevant
/// facts the reducer emits as effects, after their writes have landed.
///
/// "After" is the useful property. A consumer hearing `.arrived` can read the
/// store and find the message, its conversation and its unread state already
/// there, because `SyncEngine.handle(_:)` applies a reduction's writes before
/// it performs any of its effects.
public enum SyncAnnouncement: Sendable, Equatable {
    /// A message arrived on the live channel - never a history page or a
    /// catch-up write. See `SyncEffect.announceArrival`.
    case arrived(Message)

    /// A read position moved; announcements for messages it covers
    /// (`createdAt < upTo`) are stale. See `SyncEffect.withdrawAnnouncements`.
    case read(Conversation.ID, upTo: Date)
}
