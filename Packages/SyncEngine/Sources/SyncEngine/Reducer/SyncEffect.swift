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
