import ChatKit
import Foundation

public struct SetThreadFollowed: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "setThreadFollowed"
    public static let requiresAccount = true
    public let followed: Bool
    public let threadID: MessageThread.ID
    public let conversationID: Conversation.ID

    public init(followed: Bool, threadID: MessageThread.ID, conversationID: Conversation.ID) {
        self.followed = followed
        self.threadID = threadID
        self.conversationID = conversationID
    }
}
