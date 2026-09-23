import ChatKit
import Foundation

/// Something the engine must go and ask the backend for.
///
/// Effects exist because of one event. `ChatEvent.gap` means "continuity was
/// lost; whatever you believe may be wrong, so reconcile from scratch" - and
/// reconciling is I/O, which a pure reducer cannot do. Rather than let the
/// reducer reach for a network, it says what needs fetching and the engine
/// fetches it.
///
/// Same shape as the `(Input) -> (State, [Effect])` state machine planned for
/// `ChannelSession`, so this repo has one pattern for "pure decision, impure
/// performance" rather than two.
public enum SyncEffect: Sendable, Equatable {
    /// Re-fetch the conversation list and replace it.
    case reloadConversations

    /// Re-fetch the most recent page of one conversation's messages.
    ///
    /// The most recent page, not all history: a gap on a routine reconnect must
    /// not turn into an unbounded fetch. See the design note - history older
    /// than the visible page can stay stale until something asks for it.
    case reloadMessages(Conversation.ID)

    /// A message arrived live, and something outside the store may want to say
    /// so - a local notification today, a push gateway on a future server.
    ///
    /// **A fact, not a decision.** Whether it becomes a banner depends on who
    /// the local user is and what is on screen, neither of which a pure,
    /// stateless reducer can know; `NotificationPolicy` decides, one layer up.
    /// Emitted for `messageReceived` only. History pages and catch-up are
    /// written straight to the store by `SyncEngine.loadMoreMessages` and
    /// never pass through here, which is what keeps a reconnect from
    /// replaying old messages as fresh arrivals.
    case announceArrival(Message)

    /// A conversation's read position moved, so announcements for messages it
    /// now covers are stale.
    ///
    /// Carries the position rather than "everything in this conversation":
    /// a read on another device that predates a newer message must leave that
    /// message's banner up. Covered means `createdAt < upTo` - `findings.md`
    /// §36's strict boundary.
    case withdrawAnnouncements(Conversation.ID, upTo: Date)
}

/// What one event means: what to write, and what to go and find out.
public struct Reduction: Sendable, Equatable {
    public var writes: [StoreWrite]
    public var effects: [SyncEffect]

    public init(writes: [StoreWrite] = [], effects: [SyncEffect] = []) {
        self.writes = writes
        self.effects = effects
    }
}
