import ChatKit
import Foundation

public struct GetConversationPreview: ServiceRequestPayload {
    public typealias Response = ConversationPreview
    public static let operation = "getConversationPreview"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}
