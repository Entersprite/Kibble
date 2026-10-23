import Foundation

/// A conversation is the target; a group never impersonates an individual member.
public struct ConversationCallTarget: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID
    public let displayName: String

    public init(conversationID: Conversation.ID, displayName: String) {
        self.conversationID = conversationID
        self.displayName = displayName
    }
}

public struct ConversationCallSnapshot: Codable, Hashable, Sendable {
    public let id: UUID
    public let target: ConversationCallTarget
    public var phase: AudioCallPhase
    public var isMuted: Bool
    public var failureMessage: String?
    public var endReason: AudioCallEndReason?

    public init(
        id: UUID, target: ConversationCallTarget, phase: AudioCallPhase,
        isMuted: Bool = false, failureMessage: String? = nil, endReason: AudioCallEndReason? = nil
    ) {
        self.id = id
        self.target = target
        self.phase = phase
        self.isMuted = isMuted
        self.failureMessage = failureMessage
        self.endReason = endReason
    }

    private enum CodingKeys: String, CodingKey { case id, target, phase, isMuted, failureMessage, endReason }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: fields.decode(UUID.self, forKey: .id),
            target: fields.decode(ConversationCallTarget.self, forKey: .target),
            phase: fields.decode(AudioCallPhase.self, forKey: .phase),
            isMuted: fields.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            failureMessage: fields.decodeIfPresent(String.self, forKey: .failureMessage),
            endReason: fields.decodeIfPresent(AudioCallEndReason.self, forKey: .endReason)
        )
    }
}

/// Optional native group/space capability. Starting is quiet; joining must never
/// create a replacement meeting when the current meeting has ended.
@MainActor
public protocol ConversationAudioCallService: AudioCallService {
    var canCallConversations: Bool { get }
    func startConversationCall(to target: ConversationCallTarget, callID: UUID) async throws
    func joinConversationCall(to target: ConversationCallTarget, callID: UUID) async throws
}
