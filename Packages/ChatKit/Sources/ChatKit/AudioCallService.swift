import Foundation

/// Optional session capability for audio, separate from durable chat synchronization.
/// Operations are awaited for acknowledgement; events report ongoing call state.
/// A host supplies media through its service implementation. Provider credentials,
/// meeting references, packets and media objects never cross this contract.
@MainActor
public protocol AudioCallService: AnyObject, Sendable {
    var events: AsyncStream<AudioCallEvent> { get }
    /// Publishes supported recipients before outgoing controls become available.
    func startListening() async throws
    /// Current verified human DM recipients from the client replica. This hint
    /// creates no media or invitations; providers may further restrict it.
    func updateRecipients(_ recipients: [AudioCallRecipient]) async
    func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws
    func accept(callID: UUID) async throws
    func decline(callID: UUID) async throws
    /// Must interrupt pending connection/invitation work as well as connected media.
    func hangUp(callID: UUID) async throws
    func setMuted(_ muted: Bool, callID: UUID) async throws
    /// Settles the resources owned by this facade. Direct implementations own
    /// media; service-backed facades detach their observer. Service-owned media
    /// ends through explicit call control or account teardown, independently of
    /// a chat client's lifetime.
    func stop() async
    /// Explicitly quiesces the listener before the host repairs call sign-in.
    func prepareRecovery() async throws
    func finishRecovery() async throws
}

public extension AudioCallService {
    func updateRecipients(_: [AudioCallRecipient]) async {}
    func prepareRecovery() async throws {
        await stop()
    }

    func finishRecovery() async throws {}
}

/// Trusted provider port. The barrier is the final event after all old listener,
/// invitation and media callbacks settle; no old callback may follow it.
@MainActor
public protocol AudioCallQuiescing: AudioCallService {
    /// Immediately fences callbacks and suppresses capture before queued cleanup.
    func beginStopping()
    func pauseForRecovery(barrier: UUID) async throws
}

public struct AudioCallRecipient: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID
    public let memberID: Member.ID
    public let displayName: String

    public init(conversationID: Conversation.ID, memberID: Member.ID, displayName: String) {
        self.conversationID = conversationID
        self.memberID = memberID
        self.displayName = displayName
    }
}

/// The ID is generated locally and only correlates operations within this session.
public struct AudioCallSnapshot: Codable, Hashable, Sendable {
    public let id: UUID
    public let recipient: AudioCallRecipient
    public let direction: AudioCallDirection
    public var phase: AudioCallPhase
    public var isMuted: Bool
    /// Fixed, safe user-facing copy; never a raw provider error or diagnostic.
    public var failureMessage: String?
    /// Absent for older peers and outcomes whose cause is not known.
    public var endReason: AudioCallEndReason?
    /// Whether the other person has muted their microphone, as the provider
    /// reports it. Nil is unknown, never muted: older peers, providers without
    /// the signal and ambiguous reports all omit it.
    public var remoteMuted: Bool?

    public init(
        id: UUID, recipient: AudioCallRecipient, direction: AudioCallDirection,
        phase: AudioCallPhase, isMuted: Bool = false, failureMessage: String? = nil,
        endReason: AudioCallEndReason? = nil, remoteMuted: Bool? = nil
    ) {
        self.id = id
        self.recipient = recipient
        self.direction = direction
        self.phase = phase
        self.isMuted = isMuted
        self.failureMessage = failureMessage
        self.endReason = endReason
        self.remoteMuted = remoteMuted
    }

    enum CodingKeys: String, CodingKey {
        case id, recipient, direction, phase, isMuted, failureMessage, endReason, remoteMuted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            recipient: container.decode(AudioCallRecipient.self, forKey: .recipient),
            direction: container.decode(AudioCallDirection.self, forKey: .direction),
            phase: container.decode(AudioCallPhase.self, forKey: .phase),
            isMuted: container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            failureMessage: container.decodeIfPresent(String.self, forKey: .failureMessage),
            endReason: container.decodeIfPresent(AudioCallEndReason.self, forKey: .endReason),
            // A value this reader does not understand is unknown; it must not
            // take the rest of the call's state down with it.
            remoteMuted: try? container.decodeIfPresent(Bool.self, forKey: .remoteMuted)
        )
    }
}
