import Foundation

/// The one call a client presents, whichever service contract reported it: a
/// call to one person (`AudioCallSnapshot`) or a call in a conversation
/// (`ConversationCallSnapshot`). Each keeps its own target, so a group call
/// is never presented as a call to one of its members. A client value built
/// from the two wire snapshots; it never crosses the seam itself.
public struct AudioCallSession: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case person(AudioCallRecipient)
        case conversation(ConversationCallTarget)
    }

    public let id: UUID
    public let target: Target
    public let direction: AudioCallDirection
    public var phase: AudioCallPhase
    public var isMuted: Bool
    /// Fixed, safe user-facing copy; never a raw provider error or diagnostic.
    public var failureMessage: String?
    public var endReason: AudioCallEndReason?
    /// The other person's microphone, for a call to one person. Nil is unknown;
    /// a conversation call reports each device in its roster instead.
    public var remoteMuted: Bool?
    /// Joined a call already going on rather than starting one. Presentation
    /// only: the service decides what the join admits.
    public var isJoining: Bool

    public init(_ snapshot: AudioCallSnapshot, isJoining: Bool = false) {
        id = snapshot.id
        target = .person(snapshot.recipient)
        direction = snapshot.direction
        phase = snapshot.phase
        isMuted = snapshot.isMuted
        failureMessage = snapshot.failureMessage
        endReason = snapshot.endReason
        remoteMuted = snapshot.remoteMuted
        self.isJoining = isJoining
    }

    /// A conversation call is always this device's own start or join; nobody
    /// rings a conversation.
    public init(_ snapshot: ConversationCallSnapshot, isJoining: Bool = false) {
        id = snapshot.id
        target = .conversation(snapshot.target)
        direction = .outgoing
        phase = snapshot.phase
        isMuted = snapshot.isMuted
        failureMessage = snapshot.failureMessage
        endReason = snapshot.endReason
        remoteMuted = nil
        self.isJoining = isJoining
    }

    public var conversationID: Conversation.ID {
        switch target {
        case let .person(recipient): recipient.conversationID
        case let .conversation(target): target.conversationID
        }
    }

    public var displayName: String {
        switch target {
        case let .person(recipient): recipient.displayName
        case let .conversation(target): target.displayName
        }
    }

    /// The person called, for a call to one person; nil for a conversation.
    public var recipient: AudioCallRecipient? {
        if case let .person(recipient) = target {
            return recipient
        }
        return nil
    }

    public var isConversationCall: Bool {
        recipient == nil
    }
}
