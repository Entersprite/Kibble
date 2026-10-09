import Foundation

/// The coding of `.markThreadRead` and `.setThreadUnreadMark` (threads spec
/// §1): one more link in the cascade `init(from:)` and `encode(to:)` walk,
/// in its own file because `ChatCommand.swift` is near swiftlint's
/// `file_length`.
extension ChatCommand {
    static func decodeThreadCommand(
        _ tag: String,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> ChatCommand? {
        switch tag {
        case Tag.markThreadRead.rawValue:
            try .markThreadRead(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                threadID: container.decode(MessageThread.ID.self, forKey: .threadID),
                upTo: container.decodeWire(Date.self, forKey: .upTo)
            )
        case Tag.setThreadUnreadMark.rawValue:
            try .setThreadUnreadMark(
                conversationID: container.decode(Conversation.ID.self, forKey: .conversationID),
                threadID: container.decode(MessageThread.ID.self, forKey: .threadID),
                at: container.decodeWireIfPresent(Date.self, forKey: .at)
            )
        default:
            nil
        }
    }

    /// `at` is omitted when `nil`, never written as `null`: a cleared mark
    /// has one representation on the wire.
    func encodeThreadCommand(
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws -> Bool {
        switch self {
        case let .markThreadRead(conversationID, threadID, upTo):
            try container.encode(Tag.markThreadRead.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(threadID, forKey: .threadID)
            try container.encodeWire(upTo, forKey: .upTo)
        case let .setThreadUnreadMark(conversationID, threadID, at):
            try container.encode(Tag.setThreadUnreadMark.rawValue, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
            try container.encode(threadID, forKey: .threadID)
            try container.encodeWireIfPresent(at, forKey: .at)
        default:
            return false
        }
        return true
    }
}
