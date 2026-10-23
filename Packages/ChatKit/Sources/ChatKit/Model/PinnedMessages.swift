import Foundation

/// A complete, bounded conversation pin collection, in provider order.
/// Message addresses and media references confer no access to other conversations.
public struct PinnedMessages: Codable, Hashable, Sendable {
    public var messages: [Message]
    public var members: [Member]
    public var canModify: Bool

    public init(messages: [Message] = [], members: [Member] = [], canModify: Bool = false) {
        self.messages = messages
        self.members = members
        self.canModify = canModify
    }

    private enum CodingKeys: String, CodingKey { case messages, members, canModify }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        messages = try fields.decodeIfPresent([Message].self, forKey: .messages) ?? []
        members = try fields.decodeIfPresent([Member].self, forKey: .members) ?? []
        canModify = try fields.decodeIfPresent(Bool.self, forKey: .canModify) ?? false
    }
}

public extension Capabilities {
    var canReadMessagePins: Bool {
        extendedFlags.contains("messagePins")
    }
}
