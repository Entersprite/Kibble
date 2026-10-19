import ChatKit
import Foundation

public struct ServiceUnit: Codable, Hashable, Sendable {
    public init() {}
}

/// Open status vocabulary: an unfamiliar state must never authorize a retry.
public struct ServiceOperation: Codable, Hashable, Sendable {
    public let id: ServiceOperationID
    public let state: String
    public let result: JSONValue?
    public let failure: ServiceFailure?

    public init(
        id: ServiceOperationID,
        state: String,
        result: JSONValue? = nil,
        failure: ServiceFailure? = nil
    ) {
        self.id = id
        self.state = state
        self.result = result
        self.failure = failure
    }
}

/// Membership is intentionally conservative when the service cannot establish it.
public struct MembershipResult: Codable, Hashable, Sendable {
    public let state: String

    public init(_ membership: ConversationMembership) {
        state = switch membership {
        case .member: "member"
        case .notMember: "notMember"
        case .unknown: "unknown"
        }
    }

    public var membership: ConversationMembership {
        switch state {
        case "member": .member
        case "notMember": .notMember
        default: .unknown
        }
    }
}
