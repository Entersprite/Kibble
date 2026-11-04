import Foundation

/// Ephemeral meeting content. Resource identifiers are issued by the call source
/// and confer no authority outside that call/account/session.
public struct CallActivitiesState: Codable, Hashable, Sendable {
    public var availableActions: [String] = []
    public var messages: [CallMeetingMessage] = []
    public var reactions: [CallMeetingReaction] = []
    public var polls: [CallPoll] = []
    public var questions: [CallQuestion] = []
    public var rooms: [CallBreakoutRoom] = []
    public var people: [CallBreakoutPerson] = []
    public var artifacts: [CallArtifact] = []
    public var allowsAnonymousQuestions: Bool?
    public var attendanceReportEnabled: Bool?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case availableActions, messages, reactions, polls, questions, rooms, people, artifacts
        case attendanceReportEnabled, allowsAnonymousQuestions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableActions = try values.decodeIfPresent([String].self, forKey: .availableActions) ?? []
        messages = try values.decodeIfPresent([CallMeetingMessage].self, forKey: .messages) ?? []
        reactions = try values.decodeIfPresent([CallMeetingReaction].self, forKey: .reactions) ?? []
        polls = try values.decodeIfPresent([CallPoll].self, forKey: .polls) ?? []
        questions = try values.decodeIfPresent([CallQuestion].self, forKey: .questions) ?? []
        rooms = try values.decodeIfPresent([CallBreakoutRoom].self, forKey: .rooms) ?? []
        people = try values.decodeIfPresent([CallBreakoutPerson].self, forKey: .people) ?? []
        artifacts = try values.decodeIfPresent([CallArtifact].self, forKey: .artifacts) ?? []
        allowsAnonymousQuestions = try values.decodeIfPresent(Bool.self, forKey: .allowsAnonymousQuestions)
        attendanceReportEnabled = try values.decodeIfPresent(Bool.self, forKey: .attendanceReportEnabled)
    }
}

public struct CallMeetingMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sender: String
    public var text: String
    public init(id: UUID, sender: String, text: String) {
        self.id = id; self.sender = sender; self.text = text
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
    public init(kind: String, phase: String) {
        self.kind = kind; self.phase = phase
    }
}

public struct CallActivity: Codable, Hashable, Sendable {
    public var action: String
    public var resourceID: UUID?
    public var text: String
    public var options: [String]
    public var selections: [Int]
    public var participantIDs: [UUID] = []
    public var enabled: Bool
    public init(
        _ action: String,
        resourceID: UUID? = nil,
        text: String = "",
        options: [String] = [],
        selections: [Int] = [],
        enabled: Bool = true
    ) {
        self.action = action; self.resourceID = resourceID; self.text = text
        self.options = options; self.selections = selections; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case action, resourceID, text, options, selections, participantIDs, enabled
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
    }
}

@MainActor
public protocol CallActivitiesService: AudioCallService {
    func performCallActivity(_ activity: CallActivity, callID: UUID) async throws
}
