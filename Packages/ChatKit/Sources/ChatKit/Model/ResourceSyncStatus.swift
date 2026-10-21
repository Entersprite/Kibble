import Foundation

/// Resource synchronization is independent of the live connection's health.
public struct ResourceSyncStatus: Codable, Hashable, Sendable {
    public let resource: Resource
    public let conversationID: Conversation.ID?
    public let phase: Phase
    public let error: ChatError?

    public init(
        resource: Resource, conversationID: Conversation.ID? = nil,
        phase: Phase, error: ChatError? = nil
    ) {
        self.resource = resource
        self.conversationID = conversationID
        self.phase = phase
        self.error = error
    }

    public struct Resource: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let directory = Self(rawValue: "directory")
        public static let history = Self(rawValue: "history")
        public static let followedThreads = Self(rawValue: "followedThreads")
        public static let directoryDetails = Self(rawValue: "directoryDetails")
        public static let profiles = Self(rawValue: "profiles")
        public static let presence = Self(rawValue: "presence")
        public static let calendar = Self(rawValue: "calendar")
        public init(from decoder: any Decoder) throws {
            try self.init(rawValue: WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(rawValue, to: encoder)
        }
    }

    public struct Phase: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let catchingUp = Self(rawValue: "catchingUp")
        public static let ready = Self(rawValue: "ready")
        public static let failed = Self(rawValue: "failed")
        public init(from decoder: any Decoder) throws {
            try self.init(rawValue: WireString.decode(from: decoder))
        }

        public func encode(to encoder: any Encoder) throws {
            try WireString.encode(rawValue, to: encoder)
        }
    }
}
