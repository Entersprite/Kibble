import ChatKit
import Foundation

public struct LoadThread: ServiceRequestPayload {
    public typealias Response = MessagePage
    public static let operation = "loadThread"
    public static let requiresAccount = true
    public let threadID: MessageThread.ID
    public let conversationID: Conversation.ID

    public init(threadID: MessageThread.ID, conversationID: Conversation.ID) {
        self.threadID = threadID
        self.conversationID = conversationID
    }
}
