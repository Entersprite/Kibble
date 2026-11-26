import ChatKit
import Foundation

public struct GetConversationDetails: ServiceRequestPayload {
    public typealias Response = ConversationDetails
    public static let operation = "getConversationDetails"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}
