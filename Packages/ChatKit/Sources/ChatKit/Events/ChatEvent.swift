import Foundation

/// Everything a backend can tell a client, as one value.
///
/// This is half of the protocol. A bridge server frames these down the wire
/// (inside a `WireEnvelope`) and a local backend produces the identical values
/// in process, which is what makes the two interchangeable behind
/// `ChatBackend`.
///
/// ## Why the coding is hand-written
///
/// Every case encodes as an object with an explicit `"type"` discriminator and
/// its payload alongside it:
///
/// ```json
/// {"type": "messageDeleted", "id": "…", "conversationID": "space:1"}
/// ```
///
/// Swift can synthesise `Codable` for an enum with associated values, and that
/// synthesis is not used here. Its shape is an undocumented implementation
/// detail, it nests the payload under a key named after the case, and there is
/// nowhere in it to put a version. A protocol whose format is decided by the
/// compiler is a protocol that a toolchain upgrade can break.
///
/// ## Forward compatibility
///
/// A frame whose `type` this build has never seen decodes to
/// `.unknown(type:payload:)` with the whole object captured, and encodes back
/// out byte-for-byte. Nothing throws. Without that, shipping a bridge server
/// that emits one new event would brick every client built before it.
///
/// One exception is worth knowing about, because it is a gap rather than
/// design: `GapScope` is a closed enum, so an unrecognised discriminator
/// *inside* `gap` does throw, and takes the frame with it. `ConnectionState`
/// used to share that gap; it closed with the reconnect taxonomy's wire
/// change, which gave it its own `.unknown(String)` case. `ChatError` absorbs
/// an unrecognised discriminator, losing the payload. A field that a version 1
/// encoder always writes is required when decoding: its absence is a
/// malformed frame, not an old peer.
public enum ChatEvent: Codable, Hashable, Sendable {
    case connectionStateChanged(ConnectionState)

    /// The account operating this session, discovered once per connect
    /// (`get_self_user_status`, for a real bridge) or supplied up front by a
    /// fixture. Carries a full `Member` rather than a bare `Member.ID`: the
    /// server already knows the local user's id and kind when it says this,
    /// `get_members` need not be asked about someone the client was just told
    /// about, and an id with nothing behind it cannot be rendered as "you"
    /// anywhere.
    ///
    /// `displayName` is very often `nil` here: `get_self_user_status` returns
    /// only an id, never a name. A client fills the name in the ordinary way,
    /// once `get_members` reports the same id as a member of some
    /// conversation - the same record, arriving twice, is not a conflict to
    /// resolve.
    case selfIdentified(Member)

    /// The whole list, not a delta. Sent on connect and whenever the set of
    /// conversations changes shape.
    case conversationsChanged([Conversation])

    /// One conversation's snapshot has been replaced.
    case conversationUpdated(Conversation)

    case messageReceived(Message)
    case messageUpdated(Message)

    /// A tombstone arrived. The `Message` itself may also be re-sent with
    /// `isDeleted` set; this event exists for the case where the client has the
    /// message and only needs to be told.
    case messageDeleted(id: Message.ID, in: Conversation.ID)

    /// The complete reaction set for a message, not a diff. Reaction counts are
    /// small and a diff would need ordering guarantees this protocol does not
    /// offer.
    case reactionChanged(messageID: Message.ID, reactions: [Reaction])

    case typingChanged(conversationID: Conversation.ID, member: Member.ID, isTyping: Bool)

    /// `unread` is the count *after* the change, so a client never has to
    /// compute it.
    case readStateChanged(conversationID: Conversation.ID, lastReadAt: Date, unread: Int)

    /// Full member records rather than identifiers, because this event is where
    /// a client first learns that a member exists. `Conversation.members`
    /// carries identifiers only, and something has to fill the store they point
    /// into.
    case membersChanged(conversationID: Conversation.ID, members: [Member])

    /// Member records learned outside any conversation's membership - who
    /// someone is, and nothing about where they belong.
    ///
    /// `membersChanged` cannot carry these: it *replaces* a conversation's
    /// membership, and the usual case is a message sender in a space, where
    /// the world response lists no members at all (`findings.md` §37.5). A
    /// sender is not necessarily a member either - someone who has since left
    /// still has a name. So this fills the directory and touches no
    /// membership. An older client decodes it as `.unknown` and loses only
    /// names.
    case membersResolved([Member])

    case presenceChanged(member: Member.ID, presence: Presence)

    /// Someone's status changed, or was cleared (`nil`). A claim about now,
    /// like `presenceChanged`. An older client decodes it as `.unknown` and
    /// loses only the status.
    case statusChanged(member: Member.ID, status: MemberStatus?)

    /// **Continuity was lost.** Whatever the client believes about `scope` may
    /// be wrong, and the only correct response is to reconcile from scratch for
    /// that scope — not to patch, not to assume the next event will fix it.
    ///
    /// It is emitted when:
    ///
    /// - the event buffer overflowed, so events were dropped rather than
    ///   delivered late;
    /// - the session was invalidated, because a new session's stream is not a
    ///   continuation of the old one's;
    /// - catch-up aborted. The internal protocol's own catch-up can answer
    ///   `ABORTED_CUTOFF_EXCEEDED` — there was more history than it was willing
    ///   to send — and a backend must report that as a gap rather than pretend
    ///   the events it did get are the whole story.
    ///
    /// `reason` is for logs. A client must never branch on it: the set of
    /// reasons is open and a client that handles only the ones it knows will
    /// silently mishandle the rest.
    case gap(scope: GapScope, reason: String)

    /// Something failed in a way the client should know about, without the
    /// stream ending.
    case backendError(ChatError)

    /// A frame from a newer backend, kept whole. `type` is its discriminator;
    /// `payload` is the entire object as it arrived, including that
    /// discriminator, and it re-encodes verbatim.
    case unknown(type: String, payload: JSONValue)
}
