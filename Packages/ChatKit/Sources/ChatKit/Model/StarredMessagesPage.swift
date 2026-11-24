import Foundation

public struct StarredMessagesPage: Codable, Hashable, Sendable {
    public let messages: [Message]
    public let members: [Member]
    public let nextCursor: String?

    public init(messages: [Message], members: [Member] = [], nextCursor: String? = nil) {
        self.messages = messages
        self.members = members
        self.nextCursor = nextCursor
    }
}

public extension ChatBackend {
    func starredMessages(after _: String?) async throws -> StarredMessagesPage {
        throw ChatError.unsupported(capability: "starredMessages")
    }

    func setMessageStarred(_: Bool, at _: MessageAddress) async throws {
        throw ChatError.unsupported(capability: "starredMessages")
    }
}

public extension Capabilities {
    var canStarMessages: Bool {
        extendedFlags.contains("starredMessages")
    }
}
