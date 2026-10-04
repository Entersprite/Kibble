import ChatKit
import Foundation

/// One change to the store, as a value.
///
/// The reducer produces these and never performs them, which is what makes it
/// testable without a database and runnable inside a server that might not have
/// the same one. A `StoreWrite` says *what the store must become*, never how a
/// particular schema gets there.
public enum StoreWrite: Sendable, Equatable {
    /// The connection state, for a UI that has to draw a banner and may only
    /// read the store.
    case setConnectionState(ConnectionState)

    /// The whole conversation list. Conversations absent from it are gone, not
    /// merely unmentioned - `ChatEvent.conversationsChanged` is documented as
    /// the whole list rather than a delta.
    case replaceConversations([Conversation])

    case upsertConversation(Conversation)

    /// Member records. Separate from membership because the same person appears
    /// in many conversations and the record is shared.
    case upsertMembers([Member])

    /// Who is in a conversation, in order. Replaces whatever was there.
    case setMembership(conversation: Conversation.ID, members: [Member.ID])

    case upsertMessage(Message)

    /// A message from a push. The same as `upsertMessage`, except that a
    /// stored message keeps its stored reactions: a push is never the source
    /// of truth for them (reactions spec §2.2), because in proto2 a repeated
    /// field has no presence. History pages use `upsertMessage`, which is
    /// authoritative, and `setReactions` changes them otherwise.
    ///
    /// **A tombstone keeps nothing.** A deletion arrives through this same
    /// case - the bridge maps no `messageDeleted`; `ChannelEventMapping` turns
    /// a `deleteTime` into `messageUpdated` with `isDeleted` set - so an
    /// `isDeleted` message takes its own (empty) reactions rather than what is
    /// stored, and a tombstone never draws live reaction buttons.
    case upsertMessageKeepingReactions(Message)

    /// A tombstone. The message keeps its place in the ordering, because the
    /// protocol keeps sending it and a hole would break paging.
    case markMessageDeleted(id: Message.ID, in: Conversation.ID)

    /// Removes one row outright, by id.
    ///
    /// **Not `markMessageDeleted`.** That is a tombstone for a message the
    /// server knows about and keeps sending, and it renders as "deleted" - a
    /// claim that something was posted and then withdrawn. This is for the
    /// opposite: an optimistic row for a send that *threw*, which the server
    /// never accepted, and which must leave no trace at all.
    ///
    /// **Keyed on the exact `Message.ID`, and that is the whole safety
    /// property.** Keying on `localID` looks equivalent and is not: the server
    /// echoes the client's `localID` back onto the *delivered* message
    /// (`ChannelEventMapping` maps it, `Message.localID` documents it), so on
    /// the `/api/` timeout where the POST actually landed - the echo arrives
    /// at a second, the send throws at thirty - a `localID` delete would
    /// remove the real, posted message. The user would watch a genuine message
    /// vanish beside a send-failed banner and re-send it, which is precisely
    /// the double post this retraction exists to prevent.
    ///
    /// An id the store does not hold is a no-op, not an error, and that is the
    /// mechanism rather than a leniency: once the echo has replaced the
    /// optimistic row, the id named here is already gone and the retraction
    /// correctly does nothing.
    case removeMessage(id: Message.ID)

    /// The complete reaction set for a message, not a diff.
    case setReactions(messageID: Message.ID, reactions: [Reaction])

    /// `unread` is the count after the change, so nothing downstream has to
    /// recompute it.
    case setReadState(conversation: Conversation.ID, lastReadAt: Date, unread: Int)

    /// Mark a conversation as having something unread, because a message
    /// arrived in it.
    ///
    /// `sender` travels in the write rather than the decision being made in
    /// the reducer, because the reducer is `(ChatEvent) -> (writes, effects)`
    /// and has no state to compare against - it cannot know who the local
    /// user is. The store already holds `localMemberID`, so that is where the
    /// comparison belongs.
    ///
    /// Excluding the local user is not a nicety: without it, sending a
    /// message marks your own conversation unread until the debounced
    /// auto-mark clears it two seconds later (`findings.md` §36.7), which
    /// reads as the dot flickering on the row you are typing in.
    case markUnread(conversation: Conversation.ID, sender: Member.ID)

    case setTyping(conversation: Conversation.ID, member: Member.ID, isTyping: Bool)
    case setPresence(member: Member.ID, presence: Presence)
    /// `nil` clears it. A claim about now, dropped by `clearEphemeralState`.
    case setStatus(member: Member.ID, status: MemberStatus?)

    /// Who the local user is. Durable, unlike the rest of this file's session
    /// writes: an account signing in stays who it is on the next launch, so
    /// this is deliberately not among what `clearEphemeralState` drops.
    case setLocalMember(Member.ID)

    /// The last thing that went wrong, kept **typed** rather than rendered: a
    /// client must be able to tell "sign in again" from "the network hiccuped",
    /// and a string cannot be switched on. `nil` clears it.
    case setLastError(ChatError?)

    /// The Mentions list's backfill status (the mentions-list spec §2): a
    /// claim about *now*, which `clearEphemeralState` drops.
    case setMentionBackfill(MentionBackfillStatus)

    /// Drops everything that is a claim about *now*: typing, presence, status, the
    /// connection state, the last error, and the Mentions backfill's status.
    ///
    /// Issued at startup, not by the reducer. Restoring "Maya is typing" from
    /// three days ago is a bug rather than a cache hit - and so is a fresh
    /// process showing "connected" because that is what the database said when
    /// it was last written. Found by launching the app against a backend that
    /// could not authenticate and watching it claim to be connected.
    case clearEphemeralState
}
