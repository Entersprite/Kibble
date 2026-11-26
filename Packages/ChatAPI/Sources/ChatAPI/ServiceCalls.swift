import ChatKit
import Foundation

/// Complete ephemeral state for the authenticated device, independent of chat replay.
public struct ServiceCallState: Codable, Hashable, Sendable {
    public var version: String
    public var sourceID: UUID? {
        let parts = version.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let sequence = UInt64(parts[1]),
              String(sequence) == parts[1] else { return nil }
        return UUID(uuidString: String(parts[0]))
    }

    public var isListening: Bool
    /// No listener outcome has arrived yet. Absence preserves older peers' status semantics.
    public var isListenerStarting: Bool
    public var recipients: [AudioCallRecipient]
    public var call: AudioCallSnapshot?
    public var lastEvent: AudioCallEvent?
    /// Nil for older peers/sources without explicit existing-call admission.
    public var supportsExistingJoin: Bool?
    public var supportsConversationCalls: Bool?
    public var supportsMeetingLinks: Bool?
    public var supportsMeetingLinkCreation: Bool?
    public var supportsMeetingLinkPreview: Bool?
    public var supportsMeetingJoinMedia: Bool?
    public var meetingLinkHosts: [String]?
    public var conversationCall: ConversationCallSnapshot?
    public var meetingCall: ConversationCallSnapshot?
    public var participants: [CallParticipantDevice]?
    public var interaction: CallInteractionState?

    public var currentCallID: UUID? {
        meetingCall?.id ?? conversationCall?.id ?? call?.id
    }

    public var currentPhase: AudioCallPhase? {
        meetingCall?.phase ?? conversationCall?.phase ?? call?.phase
    }

    public init(
        version: String, isListening: Bool = false, isListenerStarting: Bool = false,
        recipients: [AudioCallRecipient] = [],
        call: AudioCallSnapshot? = nil, lastEvent: AudioCallEvent? = nil,
        supportsExistingJoin: Bool? = nil, supportsConversationCalls: Bool? = nil,
        supportsMeetingLinks: Bool? = nil, supportsMeetingLinkCreation: Bool? = nil,
        supportsMeetingLinkPreview: Bool? = nil, supportsMeetingJoinMedia: Bool? = nil,
        meetingLinkHosts: [String]? = nil,
        conversationCall: ConversationCallSnapshot? = nil, meetingCall: ConversationCallSnapshot? = nil,
        participants: [CallParticipantDevice]? = nil,
        interaction: CallInteractionState? = nil
    ) {
        self.version = version; self.isListening = isListening; self.recipients = recipients
        self.isListenerStarting = isListenerStarting
        self.call = call; self.lastEvent = lastEvent
        self.supportsExistingJoin = supportsExistingJoin
        self.supportsConversationCalls = supportsConversationCalls
        self.supportsMeetingLinks = supportsMeetingLinks
        self.supportsMeetingLinkCreation = supportsMeetingLinkCreation
        self.supportsMeetingLinkPreview = supportsMeetingLinkPreview
        self.supportsMeetingJoinMedia = supportsMeetingJoinMedia
        self.meetingLinkHosts = meetingLinkHosts
        self.conversationCall = conversationCall
        self.meetingCall = meetingCall
        self.participants = participants
        self.interaction = interaction
    }

    private enum CodingKeys: String, CodingKey {
        case meetingCall
        case version, isListening, isListenerStarting, recipients, call, lastEvent, supportsExistingJoin
        case supportsConversationCalls, supportsMeetingLinks, supportsMeetingLinkCreation,
             supportsMeetingLinkPreview, supportsMeetingJoinMedia,
             meetingLinkHosts,
             conversationCall,
             participants,
             interaction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(String.self, forKey: .version),
            isListening: container.decode(Bool.self, forKey: .isListening),
            isListenerStarting: container.decodeIfPresent(Bool.self, forKey: .isListenerStarting) ?? false,
            recipients: container.decode([AudioCallRecipient].self, forKey: .recipients),
            call: container.decodeIfPresent(AudioCallSnapshot.self, forKey: .call),
            lastEvent: container.decodeIfPresent(AudioCallEvent.self, forKey: .lastEvent),
            supportsExistingJoin: container.decodeIfPresent(Bool.self, forKey: .supportsExistingJoin),
            supportsConversationCalls: container.decodeIfPresent(
                Bool.self,
                forKey: .supportsConversationCalls
            ),
            supportsMeetingLinks: container.decodeIfPresent(Bool.self, forKey: .supportsMeetingLinks),
            supportsMeetingLinkCreation: container.decodeIfPresent(
                Bool.self,
                forKey: .supportsMeetingLinkCreation
            ),
            supportsMeetingLinkPreview: container.decodeIfPresent(
                Bool.self,
                forKey: .supportsMeetingLinkPreview
            ),
            supportsMeetingJoinMedia: container.decodeIfPresent(Bool.self, forKey: .supportsMeetingJoinMedia),
            meetingLinkHosts: container.decodeIfPresent([String].self, forKey: .meetingLinkHosts),
            conversationCall: container.decodeIfPresent(
                ConversationCallSnapshot.self,
                forKey: .conversationCall
            ),
            meetingCall: container.decodeIfPresent(ConversationCallSnapshot.self, forKey: .meetingCall),
            participants: container.decodeIfPresent([CallParticipantDevice].self, forKey: .participants),
            interaction: container.decodeIfPresent(CallInteractionState.self, forKey: .interaction)
        )
    }
}

/// A bounded long poll. The device comes from trusted transport context.
public struct ReadCallState: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "readCallState"
    public static let requiresAccount = true
    public let after: String?
    public let waitMilliseconds: Int

    public init(after: String? = nil, waitMilliseconds: Int = 20000) {
        self.after = after; self.waitMilliseconds = waitMilliseconds
    }
}

/// Call control is ephemeral and never replayed from the durable chat ledger.
/// Unknown actions are refused. Reusing a start callID cannot ring twice.
public struct ControlCall: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "controlCall"
    public static let requiresAccount = true
    public let action: String
    public let callID: UUID?
    public let recipient: AudioCallRecipient?
    public let muted: Bool?
    public let sourceID: UUID?

    public init(
        action: String, callID: UUID? = nil, recipient: AudioCallRecipient? = nil, muted: Bool? = nil,
        sourceID: UUID? = nil
    ) {
        self.sourceID = sourceID
        self.action = action; self.callID = callID; self.recipient = recipient; self.muted = muted
    }
}

/// Uses the same ephemeral session, source fence and device reservation as DM calls.
public struct ControlConversationCall: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "controlConversationCall"
    public static let requiresAccount = true
    public let action: String
    public let conversationID: Conversation.ID
    public let callID: UUID
    public let sourceID: UUID

    public init(action: String, conversationID: Conversation.ID, callID: UUID, sourceID: UUID) {
        self.action = action
        self.conversationID = conversationID
        self.callID = callID
        self.sourceID = sourceID
    }
}
