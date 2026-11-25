import Foundation

/// Ephemeral meeting content. Resource identifiers are issued by the call source
/// and confer no authority outside that call/account/session.
public struct CallActivitiesState: Codable, Hashable, Sendable {
    public var availableActions: [String] = []
    public var messages: [CallMeetingMessage] = []
    public var waitingRoomMessages: [CallMeetingMessage]?
    public var reactions: [CallMeetingReaction] = []
    public var polls: [CallPoll] = []
    public var questions: [CallQuestion] = []
    public var rooms: [CallBreakoutRoom] = []
    /// The source has started closing breakout rooms and the transition is still in progress.
    public var breakoutClosing: Bool?
    /// The source explicitly confirmed that the breakout session is closed.
    public var breakoutClosed: Bool?
    public var people: [CallBreakoutPerson] = []
    public var waitingParticipants: [CallWaitingParticipant] = []
    public var artifacts: [CallArtifact] = []
    public var artifactFiles: [CallArtifactFile] = []
    public var agendaAttachments: [CallAgendaAttachment]?
    public var agendaGuests: [CallAgendaGuest]?
    public var captions: CallCaptionState?
    public var captionLanguages: CallCaptionLanguages?
    public var recordingCaptionLanguages: [String] = []
    public var hostSettings: CallHostSettings?
    public var meetingChat: CallMeetingChat?
    public var microphoneRestricted: Bool?
    public var sharedPinLimit: Int?
    public var moderatorMute: UUID?
    /// Identifies the latest observed lowering of this device's raised hand.
    public var ownHandLowered: UUID?
    public var automaticHandLowering: CallAutomaticHandLowering?
    public var allowsAnonymousQuestions: Bool?
    public var attendanceReportEnabled: Bool?
    public init() {}

    public func canSetRecordingAndTranscriptionEnabled(_ enabled: Bool) -> Bool {
        ["recording", "transcription"].allSatisfy { kind in
            availableActions.contains(kind) && artifacts.first(where: { $0.kind == kind })?
                .canSetEnabled(enabled) == true
        }
    }

    public func acceptsRecordingCaptionChoice(_ activity: CallActivity) -> Bool {
        guard let language = activity.recordingCaptionLanguage else { return true }
        return activity.action == "recording" && activity.enabled && recordingCaptionLanguages
            .contains(language)
    }

    private enum CodingKeys: String, CodingKey {
        case availableActions, messages, reactions, polls, questions, rooms, people, artifacts
        case waitingParticipants, waitingRoomMessages, agendaAttachments, agendaGuests, breakoutClosing,
             breakoutClosed
        case attendanceReportEnabled, allowsAnonymousQuestions, captions, captionLanguages, artifactFiles
        case recordingCaptionLanguages, hostSettings, meetingChat, microphoneRestricted, moderatorMute,
             sharedPinLimit, ownHandLowered, automaticHandLowering
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableActions = try values.decodeIfPresent([String].self, forKey: .availableActions) ?? []
        messages = try values.decodeIfPresent([CallMeetingMessage].self, forKey: .messages) ?? []
        waitingRoomMessages = try values.decodeIfPresent(
            [CallMeetingMessage].self,
            forKey: .waitingRoomMessages
        )
        reactions = try values.decodeIfPresent([CallMeetingReaction].self, forKey: .reactions) ?? []
        polls = try values.decodeIfPresent([CallPoll].self, forKey: .polls) ?? []
        questions = try values.decodeIfPresent([CallQuestion].self, forKey: .questions) ?? []
        rooms = try values.decodeIfPresent([CallBreakoutRoom].self, forKey: .rooms) ?? []
        breakoutClosing = try values.decodeIfPresent(Bool.self, forKey: .breakoutClosing)
        breakoutClosed = try values.decodeIfPresent(Bool.self, forKey: .breakoutClosed)
        people = try values.decodeIfPresent([CallBreakoutPerson].self, forKey: .people) ?? []
        waitingParticipants = try values.decodeIfPresent(
            [CallWaitingParticipant].self,
            forKey: .waitingParticipants
        ) ?? []
        artifacts = try values.decodeIfPresent([CallArtifact].self, forKey: .artifacts) ?? []
        artifactFiles = try values.decodeIfPresent([CallArtifactFile].self, forKey: .artifactFiles) ?? []
        agendaAttachments = try values.decodeIfPresent(
            [CallAgendaAttachment].self,
            forKey: .agendaAttachments
        )
        agendaGuests = try values.decodeIfPresent([CallAgendaGuest].self, forKey: .agendaGuests)
        captions = try values.decodeIfPresent(CallCaptionState.self, forKey: .captions)
        captionLanguages = try values.decodeIfPresent(CallCaptionLanguages.self, forKey: .captionLanguages)
        recordingCaptionLanguages = try values.decodeIfPresent(
            [String].self,
            forKey: .recordingCaptionLanguages
        ) ?? []
        hostSettings = try values.decodeIfPresent(CallHostSettings.self, forKey: .hostSettings)
        meetingChat = try values.decodeIfPresent(CallMeetingChat.self, forKey: .meetingChat)
        microphoneRestricted = try values.decodeIfPresent(Bool.self, forKey: .microphoneRestricted)
        sharedPinLimit = try? values.decodeIfPresent(Int.self, forKey: .sharedPinLimit)
        moderatorMute = try values.decodeIfPresent(UUID.self, forKey: .moderatorMute)
        ownHandLowered = try? values.decodeIfPresent(UUID.self, forKey: .ownHandLowered)
        automaticHandLowering = try? values.decodeIfPresent(
            CallAutomaticHandLowering.self, forKey: .automaticHandLowering
        )
        allowsAnonymousQuestions = try values.decodeIfPresent(Bool.self, forKey: .allowsAnonymousQuestions)
        attendanceReportEnabled = try values.decodeIfPresent(Bool.self, forKey: .attendanceReportEnabled)
    }
}

public struct CallAgendaAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: URL {
        url
    }

    public let title: String?
    public let url: URL

    public init(title: String? = nil, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct CallAutomaticHandLowering: Codable, Hashable, Sendable {
    public let id: UUID
    public let deadline: Date

    public init(id: UUID, deadline: Date) {
        self.id = id
        self.deadline = deadline
    }
}

/// The existing conversation associated with this call. Its own account
/// membership and posting rules still apply.
public struct CallMeetingChat: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID
    public let canSend: Bool

    public init(conversationID: Conversation.ID, canSend: Bool) {
        self.conversationID = conversationID
        self.canSend = canSend
    }
}

public struct CallHostSettings: Codable, Hashable, Sendable {
    public var managementEnabled: Bool
    public var reactionsAllowed: Bool
    public var chatMessagesAllowed: Bool?
    public var screenSharingAllowed: Bool?
    public var microphoneAllowed: Bool?
    public var cameraAllowed: Bool?
    public var joiningBeforeHostAllowed: Bool?
    public var waitingRoomEnabled: Bool?
    public var meetingAccess: CallMeetingAccess?

    public init(
        managementEnabled: Bool, reactionsAllowed: Bool, chatMessagesAllowed: Bool? = nil,
        screenSharingAllowed: Bool? = nil, microphoneAllowed: Bool? = nil, cameraAllowed: Bool? = nil,
        joiningBeforeHostAllowed: Bool? = nil, waitingRoomEnabled: Bool? = nil,
        meetingAccess: CallMeetingAccess? = nil
    ) {
        self.managementEnabled = managementEnabled
        self.reactionsAllowed = reactionsAllowed
        self.chatMessagesAllowed = chatMessagesAllowed
        self.screenSharingAllowed = screenSharingAllowed
        self.microphoneAllowed = microphoneAllowed
        self.cameraAllowed = cameraAllowed
        self.joiningBeforeHostAllowed = joiningBeforeHostAllowed
        self.waitingRoomEnabled = waitingRoomEnabled
        self.meetingAccess = meetingAccess
    }
}

public struct CallMeetingAccess: Codable, Hashable, Sendable {
    public var preset: String
    public var availablePresets: [String]
    public var joinRequestsAllowed: Bool?

    public init(preset: String, availablePresets: [String], joinRequestsAllowed: Bool? = nil) {
        self.preset = preset
        self.availablePresets = availablePresets
        self.joinRequestsAllowed = joinRequestsAllowed
    }
}

/// A file returned by the call source and available to open in the browser.
public struct CallArtifactFile: Codable, Hashable, Sendable, Identifiable {
    public var id: URL {
        url
    }

    public let kind: String
    public let title: String?
    public let url: URL

    public init(kind: String, title: String? = nil, url: URL) {
        self.kind = kind
        self.title = title
        self.url = url
    }
}

public struct CallCaptionLanguages: Codable, Hashable, Sendable {
    public let live: [String]
    public let translations: [String: [String]]

    public init(live: [String], translations: [String: [String]]) {
        self.live = live
        self.translations = translations
    }

    public var meetingLanguages: [String] {
        Array(Set(live).union(translations.keys)).sorted()
    }

    public func supports(spoken: String, display: String) -> Bool {
        spoken == display ? live.contains(spoken) : translations[spoken]?.contains(display) == true
    }
}

public struct CallCaptionState: Codable, Hashable, Sendable {
    public let spokenLanguage: String
    public let displayLanguage: String
    public var segments: [CallCaptionSegment]

    public init(spokenLanguage: String, displayLanguage: String, segments: [CallCaptionSegment] = []) {
        self.spokenLanguage = spokenLanguage
        self.displayLanguage = displayLanguage
        self.segments = segments
    }
}

public struct CallCaptionSegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let speaker: String?
    public let text: String

    public init(id: UUID, speaker: String?, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

public struct CallMeetingMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sender: String
    public var text: String
    public var isPinned: Bool?
    public var canChangePin: Bool?
    public init(id: UUID, sender: String, text: String, isPinned: Bool? = nil, canChangePin: Bool? = nil) {
        self.id = id; self.sender = sender; self.text = text
        self.isPinned = isPinned; self.canChangePin = canChangePin
    }
}

public struct CallMeetingReaction: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var participantID: UUID?
    public var sender: String
    public var emoji: String
    public init(id: UUID, participantID: UUID? = nil, sender: String, emoji: String) {
        self.id = id; self.participantID = participantID; self.sender = sender; self.emoji = emoji
    }
}

public struct CallPoll: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var question: String
    public var options: [String]
    public var votes: [Int]
    public var selections: [Int]
    public var isOpen: Bool
    public var resultsVisible: Bool?
    public init(
        id: UUID,
        question: String,
        options: [String],
        votes: [Int] = [],
        selections: [Int] = [],
        isOpen: Bool,
        resultsVisible: Bool? = nil
    ) {
        self.id = id; self.question = question; self.options = options; self.votes = votes
        self.selections = selections; self.isOpen = isOpen; self.resultsVisible = resultsVisible
    }
}

public struct CallQuestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var votes: Int
    public var hasVoted: Bool
    public var isAnswered: Bool
    public init(id: UUID, text: String, votes: Int = 0, hasVoted: Bool = false, isAnswered: Bool = false) {
        self.id = id; self.text = text; self.votes = votes; self.hasVoted = hasVoted; self
            .isAnswered = isAnswered
    }
}

public struct CallBreakoutPerson: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) {
        self.id = id; self.name = name
    }
}

public struct CallBreakoutRoom: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isOpen: Bool
    public var joinURL: URL?
    public var participants: [UUID]
    public init(id: UUID, name: String, isOpen: Bool, participants: [UUID] = [], joinURL: URL? = nil) {
        self.id = id; self.name = name; self.isOpen = isOpen; self.participants = participants; self
            .joinURL = joinURL
    }
}

public struct CallArtifact: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        kind
    }

    public var kind: String
    public var phase: String
    public var recordingCaptionLanguage: String?
    /// An optional, portable reason for a pending or failed start.
    public var issue: String?
    public init(kind: String, phase: String, recordingCaptionLanguage: String? = nil, issue: String? = nil) {
        self.kind = kind
        self.phase = phase
        self.recordingCaptionLanguage = recordingCaptionLanguage
        self.issue = issue
    }

    public func canSetEnabled(_ enabled: Bool) -> Bool {
        enabled ? phase == "stopped" || phase == "preconfigured" : phase == "active" || phase == "starting"
    }
}

public enum CallArtifactIssue: String, Sendable {
    case participantCompatibility, initializationFailed
}

/// The result of one or both operations remains unconfirmed after a paired request.
public enum CallArtifactPairError: Error, Sendable {
    case recordingUnconfirmed, transcriptionUnconfirmed, bothUnconfirmed
}

public struct CallActivity: Codable, Hashable, Sendable {
    public var action: String
    public var resourceID: UUID?
    public var text: String
    public var options: [String]
    public var selections: [Int]
    public var participantIDs: [UUID] = []
    public var enabled: Bool
    public var recordingCaptionLanguage: String?
    public init(
        _ action: String,
        resourceID: UUID? = nil,
        text: String = "",
        options: [String] = [],
        selections: [Int] = [],
        enabled: Bool = true,
        recordingCaptionLanguage: String? = nil
    ) {
        self.action = action; self.resourceID = resourceID; self.text = text
        self.options = options; self.selections = selections; self.enabled = enabled
        self.recordingCaptionLanguage = recordingCaptionLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case action, resourceID, text, options, selections, participantIDs, enabled, recordingCaptionLanguage
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decode(String.self, forKey: .action)
        resourceID = try values.decodeIfPresent(UUID.self, forKey: .resourceID)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        options = try values.decodeIfPresent([String].self, forKey: .options) ?? []
        selections = try values.decodeIfPresent([Int].self, forKey: .selections) ?? []
        participantIDs = try values.decodeIfPresent([UUID].self, forKey: .participantIDs) ?? []
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        recordingCaptionLanguage = try values.decodeIfPresent(String.self, forKey: .recordingCaptionLanguage)
    }
}

@MainActor
public protocol CallActivitiesService: AudioCallService {
    func performCallActivity(_ activity: CallActivity, callID: UUID) async throws
}
