import ChatKit
import Foundation

/// What each event means for the store.
///
/// Pure, and takes **no prior state** - which is a property of `ChatKit`'s event
/// design rather than a simplification here. `conversationsChanged` carries the
/// whole list, `reactionChanged` the complete reaction set, `readStateChanged`
/// the count after the change. The events were built to be applied without
/// knowing what came before, so there is nothing to diff against.
///
/// **This file must not import a database.** It is the half of the sync layer
/// that a bridge server runs verbatim, and the moment it knows about GRDB the
/// server needs its own copy - which is how read state and history end up with
/// two sources of truth. `scripts/test.sh` enforces the import ban.
public enum SyncReducer {
    /// The writes and effects one event implies.
    ///
    /// Routed by family rather than written as one switch, because fourteen
    /// cases exceed swiftlint's complexity limit. The routing switch is
    /// exhaustive on purpose: a new `ChatEvent` case stops this compiling until
    /// someone decides what it means for the store.
    public static func reduce(_ event: ChatEvent) -> Reduction {
        switch event {
        case .messageReceived, .messageUpdated, .messageDeleted, .reactionChanged:
            supersedingStaleError(reduceMessageEvent(event))
        case .conversationsChanged, .conversationUpdated, .membersChanged,
             .readStateChanged, .typingChanged, .presenceChanged:
            supersedingStaleError(reduceConversationEvent(event))
        case .selfIdentified:
            supersedingStaleError(reduceSessionEvent(event))
        case .connectionStateChanged, .backendError, .gap, .unknown:
            reduceSessionEvent(event)
        }
    }

    /// Marks a stale `lastError` superseded by the forward progress `reduction`
    /// itself proves just happened.
    ///
    /// **Why this exists.** A one-off `/api/` failure - a `get_members` call
    /// that failed on an otherwise healthy channel, say - used to outlive its
    /// own relevance: nothing about *connection state* changes when a single
    /// call fails, so `clearedError(by:)` alone never fired again, and the
    /// banner sat there for the rest of the session even after the exact same
    /// kind of call went on to succeed. This is the same reasoning
    /// `clearedError(by:)`'s own doc comment already states for
    /// `.connectionStateChanged` - "an error is a claim about a moment that
    /// has passed; ... the newer claim wins" - generalised to every event
    /// whose very existence is proof the channel just did something real:
    /// a message that arrived, a conversation that changed, a membership list
    /// that resolved, this client's own identity confirmed.
    ///
    /// **Why it does not chase which specific action failed.** `ChatEvent`
    /// carries no link back to the `/api/` call that produced it, so
    /// "supersede only the matching error" is not expressible without adding
    /// causality this protocol does not have. What is expressible, and is
    /// exactly what `.connectionStateChanged` already does at a coarser
    /// grain, is "the channel just proved it is working, so whatever went
    /// wrong before this moment is no longer the last word." A banner that
    /// clears a little too eagerly is a UI nit; one that never clears is the
    /// bug this fixes.
    ///
    /// **Why a persistent problem still shows.** `.backendError`, `.gap` and
    /// `.unknown` are excluded, and `.connectionStateChanged` keeps going
    /// through its own narrower `clearedError(by:)` untouched - blanket
    /// superseding there would erase the diagnosis `.disconnected` exists to
    /// carry, one event after it arrived. For everything routed through here,
    /// a session that is actually dead cannot keep producing the events that
    /// supersede it, so the newer claim only wins because it is true.
    private static func supersedingStaleError(_ reduction: Reduction) -> Reduction {
        Reduction(writes: reduction.writes + [.setLastError(nil)], effects: reduction.effects)
    }

    private static func reduceMessageEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .messageReceived(message):
            // No longer identical to `messageUpdated`. Both still end with the
            // store holding the message, but only an *arrival* can make a
            // conversation unread - an edit to something already read must
            // not raise the dot again.
            Reduction(writes: [
                .upsertMessage(message),
                .markUnread(conversation: message.conversationID, sender: message.sender)
            ])
        case let .messageUpdated(message):
            Reduction(writes: [.upsertMessage(message)])
        case let .messageDeleted(id, conversationID):
            Reduction(writes: [.markMessageDeleted(id: id, in: conversationID)])
        case let .reactionChanged(messageID, reactions):
            Reduction(writes: [.setReactions(messageID: messageID, reactions: reactions)])
        default:
            Reduction()
        }
    }

    private static func reduceConversationEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .conversationsChanged(conversations):
            Reduction(writes: [.replaceConversations(conversations)])
        case let .conversationUpdated(conversation):
            Reduction(writes: [.upsertConversation(conversation)])
        case let .membersChanged(conversationID, members):
            Reduction(writes: [
                .upsertMembers(members),
                .setMembership(conversation: conversationID, members: members.map(\.id))
            ])
        case let .readStateChanged(conversationID, lastReadAt, unread):
            Reduction(writes: [
                .setReadState(conversation: conversationID, lastReadAt: lastReadAt, unread: unread)
            ])
        case let .typingChanged(conversationID, member, isTyping):
            Reduction(writes: [
                .setTyping(conversation: conversationID, member: member, isTyping: isTyping)
            ])
        case let .presenceChanged(member, presence):
            Reduction(writes: [.setPresence(member: member, presence: presence)])
        default:
            Reduction()
        }
    }

    private static func reduceSessionEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .connectionStateChanged(state):
            Reduction(writes: [.setConnectionState(state)] + clearedError(by: state))
        case let .selfIdentified(member):
            // Both halves, the same way membersChanged does: who the local
            // user is, and the record itself so the name resolves like
            // anyone else's.
            Reduction(writes: [
                .setLocalMember(member.id),
                .upsertMembers([member])
            ])
        case let .backendError(error):
            Reduction(writes: [.setLastError(error)])
        case let .gap(scope, _):
            switch scope {
            case .everything:
                Reduction(effects: [.reloadConversations])
            case let .conversation(id):
                Reduction(effects: [.reloadMessages(id)])
            }
        case .unknown:
            // Deliberately nothing. A client built before a feature ignores it
            // rather than failing; that is what forward compatibility buys, and
            // a test asserts this stays intentional.
            Reduction()
        default:
            Reduction()
        }
    }

    /// Whether a new connection state supersedes the last error.
    ///
    /// Nothing but `clearEphemeralState` at launch used to clear `lastError`,
    /// so one failed send made the banner permanent for the rest of the
    /// session - and the banner is where `reconnecting(attempt:)` is drawn, so
    /// the client silently stopped being able to say "Reconnecting, attempt
    /// 2…" ever again. An error is a claim about a moment that has passed;
    /// a connection that is being *established* is a claim about now, and the
    /// newer claim wins.
    ///
    /// **`disconnected` deliberately does not clear.** A backend reports the
    /// reason it stopped as `.backendError` and then reports the stop itself -
    /// `LocalBridgeBackend.channelStopped` emits exactly that pair - so
    /// clearing here would erase the diagnosis one event after it arrived and
    /// leave "Disconnected." with no cause. `idle` does not clear either: it
    /// is the value a fresh process starts from, not something a session
    /// transitions into.
    ///
    /// **`.unknown` does not clear either, grouped with `idle`/`disconnected`
    /// rather than with the states that mean "trying now".** An earlier
    /// version of this grouped it with `.connecting`/`.reconnecting`/
    /// `.connected` instead, reading spec §3.4's "degrade toward optimism" as
    /// licensing that. It does not: that rule governs how an
    /// *uninterpretable state is rendered* - `ChatWindow` shows "Connecting…"
    /// rather than alarming someone - and it does not license discarding a
    /// diagnosis that has already arrived. An unrecognised state is absence of
    /// information about what a newer peer meant, not evidence of recovery,
    /// and the repo's harder wire rule - assume less, never more - is the one
    /// that actually governs here.
    ///
    /// Concretely: a backend reports `.backendError(.notAuthenticated)`, and
    /// then a newer server sends some interim state this build does not
    /// recognise. Clearing here would wipe that diagnosis, and
    /// `ChatWindow.banner` - which gives `state.lastError` precedence over
    /// connection state - would silently downgrade "Signed out. Sign in again
    /// to keep syncing." (with its sign-in button) to "Connecting…": a real,
    /// actionable auth failure understated as routine reconnection, with the
    /// sign-in route gone. That is the "banner with no way out" bug class
    /// session 15 recorded.
    private static func clearedError(by state: ConnectionState) -> [StoreWrite] {
        switch state {
        case .connecting, .reconnecting, .connected: [.setLastError(nil)]
        case .idle, .disconnected, .unknown: []
        }
    }
}
