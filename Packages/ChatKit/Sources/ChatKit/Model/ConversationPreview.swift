import Foundation

/// Recent messages of a conversation the account has not joined, read to
/// preview it before joining (`ChatBackend.conversationPreview(_:)`). Nothing
/// in it is stored: a preview never becomes a joined conversation, a
/// transcript or a sidebar row.
///
/// `members` names the senders the client may not know, since nothing about
/// an unjoined conversation is in its directory.
public struct ConversationPreview: Codable, Hashable, Sendable {
    /// Oldest first, top-level messages only.
    public var messages: [Message]
    public var members: [Member]

    public init(messages: [Message] = [], members: [Member] = []) {
        self.messages = messages
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case messages, members }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        messages = try fields.decodeIfPresent([Message].self, forKey: .messages) ?? []
        members = try fields.decodeIfPresent([Member].self, forKey: .members) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(messages, forKey: .messages)
        try fields.encode(members, forKey: .members)
    }
}

public extension Capabilities {
    /// `ChatBackend.conversationPreview(_:)` answers rather than refusing. A
    /// preview without it shows only what the details carry.
    var canPreviewConversations: Bool {
        extendedFlags.contains("conversationPreview")
    }
}
