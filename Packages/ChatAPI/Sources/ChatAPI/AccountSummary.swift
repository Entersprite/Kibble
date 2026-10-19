import ChatKit
import Foundation

public struct AccountSummary: Codable, Hashable, Sendable {
    public let id: ConnectedAccountID
    public let selfID: Member.ID
    public let label: String
    public let connection: ConnectionState

    public init(id: ConnectedAccountID, selfID: Member.ID, label: String, connection: ConnectionState) {
        self.id = id
        self.selfID = selfID
        self.label = label
        self.connection = connection
    }
}

public struct ListAccounts: ServiceRequestPayload {
    public typealias Response = [AccountSummary]
    public static let operation = "listAccounts"
    public static let requiresAccount = false

    public init() {}
}

public struct LoadConversations: ServiceRequestPayload {
    public typealias Response = [Conversation]
    public static let operation = "loadConversations"
    public static let requiresAccount = true

    public init() {}
}

/// Coverage is explicit: a partial page cannot establish absence or deletion.
public struct MessagePage: Codable, Hashable, Sendable {
    public let messages: [Message]
    public let nextCursor: String?
    public let isComplete: Bool

    public init(messages: [Message], nextCursor: String?, isComplete: Bool) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.isComplete = isComplete
    }
}

public struct LoadMessages: ServiceRequestPayload {
    public typealias Response = MessagePage
    public static let operation = "loadMessages"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let cursor: String?

    public init(conversationID: Conversation.ID, cursor: String? = nil) {
        self.conversationID = conversationID
        self.cursor = cursor
    }
}
