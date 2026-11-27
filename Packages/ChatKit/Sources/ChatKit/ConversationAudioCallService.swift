import Foundation

/// A conversation or an explicitly supplied public meeting link. Neither
/// impersonates an individual member or creates a synthetic conversation ID.
public struct ConversationCallTarget: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID?
    public let meetingURL: URL?
    public let displayName: String

    public init(conversationID: Conversation.ID, displayName: String) {
        self.conversationID = conversationID
        meetingURL = nil
        self.displayName = displayName
    }

    public init(meetingURL: URL, displayName: String) {
        conversationID = nil
        self.meetingURL = meetingURL
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey { case conversationID, meetingURL, displayName }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try fields.decodeIfPresent(Conversation.ID.self, forKey: .conversationID)
        meetingURL = try fields.decodeIfPresent(URL.self, forKey: .meetingURL)
        displayName = try fields.decode(String.self, forKey: .displayName)
        guard (conversationID == nil) != (meetingURL == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .conversationID,
                in: fields,
                debugDescription: "Expected one call target"
            )
        }
    }
}

/// Device intent for a single explicit meeting join. It is never a device preference.
public struct MeetingJoinMedia: Codable, Hashable, Sendable {
    public var microphoneMuted: Bool
    public var cameraEnabled: Bool

    public init(microphoneMuted: Bool = false, cameraEnabled: Bool = false) {
        self.microphoneMuted = microphoneMuted
        self.cameraEnabled = cameraEnabled
    }
}

/// Optional explicit link admission. The provider validates the URL and owns
/// resolution and admission; a link is never authorization or an invitation.
@MainActor
public protocol MeetingLinkAudioCallService: AudioCallService {
    var canJoinMeetingLinks: Bool { get }
    var canCreateMeetingLinks: Bool { get }
    var canPreviewMeetingLinks: Bool { get }
    var canConfigureMeetingJoinMedia: Bool { get }
    var meetingLinkHosts: Set<String> { get }
    func normalizedMeetingLink(_ url: URL) throws -> URL
    func joinMeeting(at url: URL, callID: UUID) async throws
    func joinMeeting(at url: URL, callID: UUID, media: MeetingJoinMedia) async throws
    func createMeetingLink() async throws -> URL
    func previewMeetingTitle(at url: URL) async throws -> String?
    func previewMeetingTitle(at url: URL, reference: Date?, calendarOnly: Bool) async throws -> String?
}

public extension MeetingLinkAudioCallService {
    var canConfigureMeetingJoinMedia: Bool {
        false
    }

    func joinMeeting(at url: URL, callID: UUID, media: MeetingJoinMedia) async throws {
        guard media == MeetingJoinMedia() else {
            throw ChatError.unsupported(capability: "meetingJoinMedia")
        }
        try await joinMeeting(at: url, callID: callID)
    }

    var canPreviewMeetingLinks: Bool {
        false
    }

    func previewMeetingTitle(at _: URL) async throws -> String? {
        throw ChatError.unsupported(capability: "meetingLinkPreview")
    }

    func previewMeetingTitle(at url: URL, reference _: Date?, calendarOnly: Bool) async throws -> String? {
        guard !calendarOnly else { return nil }
        return try await previewMeetingTitle(at: url)
    }

    var canCreateMeetingLinks: Bool {
        false
    }

    func createMeetingLink() async throws -> URL {
        throw ChatError.unsupported(capability: "meetingLinkCreation")
    }

    func normalizedMeetingLink(_ url: URL) throws -> URL {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.absoluteString.utf8.count <= 2048 else {
            throw ChatError.unsupported(capability: "meetingLinks")
        }
        return url
    }

    var meetingLinkHosts: Set<String> {
        []
    }
}

public struct ConversationCallSnapshot: Codable, Hashable, Sendable {
    public let id: UUID
    public let target: ConversationCallTarget
    public var phase: AudioCallPhase
    public var isMuted: Bool
    public var failureMessage: String?
    public var endReason: AudioCallEndReason?
    public var admission: CallAdmission?

    public init(
        id: UUID, target: ConversationCallTarget, phase: AudioCallPhase,
        isMuted: Bool = false, failureMessage: String? = nil, endReason: AudioCallEndReason? = nil,
        admission: CallAdmission? = nil
    ) {
        self.id = id
        self.target = target
        self.phase = phase
        self.isMuted = isMuted
        self.failureMessage = failureMessage
        self.endReason = endReason
        self.admission = admission
    }

    private enum CodingKeys: String, CodingKey {
        case id, target, phase, isMuted, failureMessage, endReason, admission
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: fields.decode(UUID.self, forKey: .id),
            target: fields.decode(ConversationCallTarget.self, forKey: .target),
            phase: fields.decode(AudioCallPhase.self, forKey: .phase),
            isMuted: fields.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            failureMessage: fields.decodeIfPresent(String.self, forKey: .failureMessage),
            endReason: fields.decodeIfPresent(AudioCallEndReason.self, forKey: .endReason),
            admission: fields.decodeIfPresent(CallAdmission.self, forKey: .admission)
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
