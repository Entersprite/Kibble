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

    /// A tombstone. The message keeps its place in the ordering, because the
    /// protocol keeps sending it and a hole would break paging.
    case markMessageDeleted(id: Message.ID, in: Conversation.ID)

    /// The complete reaction set for a message, not a diff.
    case setReactions(messageID: Message.ID, reactions: [Reaction])

    /// `unread` is the count after the change, so nothing downstream has to
    /// recompute it.
    case setReadState(conversation: Conversation.ID, lastReadAt: Date, unread: Int)

    case setTyping(conversation: Conversation.ID, member: Member.ID, isTyping: Bool)
    case setPresence(member: Member.ID, presence: Presence)

    /// Who the local user is. Durable, unlike the rest of this file's session
    /// writes: an account signing in stays who it is on the next launch, so
    /// this is deliberately not among what `clearEphemeralState` drops.
    case setLocalMember(Member.ID)

    /// The last thing that went wrong, kept **typed** rather than rendered: a
    /// client must be able to tell "sign in again" from "the network hiccuped",
    /// and a string cannot be switched on. `nil` clears it.
    case setLastError(ChatError?)

    /// Drops everything that is a claim about *now*: typing, presence, the
    /// connection state and the last error.
    ///
    /// Issued at startup, not by the reducer. Restoring "Maya is typing" from
    /// three days ago is a bug rather than a cache hit - and so is a fresh
    /// process showing "connected" because that is what the database said when
    /// it was last written. Found by launching the app against a backend that
    /// could not authenticate and watching it claim to be connected.
    case clearEphemeralState
}
