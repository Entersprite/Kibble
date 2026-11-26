import Foundation

/// A call-local admission target, separate from joined media participants.
public struct CallWaitingParticipant: Identifiable, Codable, Hashable, Sendable {
    public enum Warning: String, Codable, Hashable, Sendable {
        case suspiciousUser, suspectedBot, potentialRisk
    }

    public let id: UUID
    public let name: String
    public let canDeny: Bool
    public let warning: Warning?
    public let isJoinRequest: Bool?

    public var isInWaitingRoom: Bool {
        !(isJoinRequest ?? canDeny)
    }

    public init(id: UUID, name: String, canDeny: Bool, warning: Warning? = nil, isJoinRequest: Bool? = nil) {
        self.id = id
        self.name = name
        self.canDeny = canDeny
        self.warning = warning
        self.isJoinRequest = isJoinRequest
    }
}
