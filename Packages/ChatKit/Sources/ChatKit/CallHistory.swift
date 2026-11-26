import Foundation

/// An account's known call records, not a promise of complete provider history.
public struct CallHistoryPage: Codable, Hashable, Sendable {
    public let messages: [Message]
    public let nextCursor: String?

    public init(messages: [Message], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct CallHistoryQuery: Codable, Hashable, Sendable {
    public let conversationID: Conversation.ID?
    public let cursor: String?
    public let limit: Int

    public init(conversationID: Conversation.ID? = nil, cursor: String? = nil, limit: Int = 50) {
        self.conversationID = conversationID
        self.cursor = cursor
        self.limit = limit
    }
}

/// Optional read port for locally retained call history. It never creates
/// calls, refreshes every conversation, or supplies current join authorization.
public protocol CallHistoryBackend: Sendable {
    func callHistory(_ query: CallHistoryQuery) async throws -> CallHistoryPage
}

/// Shared paging vocabulary for storage and deterministic providers. Clients
/// retain the cursor verbatim. Its numeric time avoids losing precision through
/// the display-oriented RFC 3339 representation of a message's timestamp.
public struct CallHistoryPosition: Codable, Sendable {
    public let time: Double
    public let messageID: String
    public let conversationID: Conversation.ID?

    public init(message: Message, query: CallHistoryQuery) {
        time = message.createdAt.timeIntervalSince1970
        messageID = message.id.rawValue
        conversationID = query.conversationID
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).base64EncodedString()
    }

    public static func decode(for query: CallHistoryQuery) throws -> Self? {
        guard (1 ... 100).contains(query.limit) else { throw CallHistoryError.invalidQuery }
        guard let cursor = query.cursor else { return nil }
        guard cursor.utf8.count <= 16384, let bytes = Data(base64Encoded: cursor),
              let value = try? JSONDecoder().decode(Self.self, from: bytes),
              value.time.isFinite, (-62_135_596_800 ... 253_402_300_799).contains(value.time),
              !value.messageID.isEmpty, value.messageID.utf8.count <= 8192,
              value.conversationID == query.conversationID else { throw CallHistoryError.invalidQuery }
        return value
    }
}

public enum CallHistoryError: Error, Sendable {
    case invalidQuery
}
