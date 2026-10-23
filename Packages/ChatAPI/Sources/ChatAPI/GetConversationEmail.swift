import ChatKit

public struct GetConversationEmail: ServiceRequestPayload {
    public typealias Response = ConversationEmail
    public static let operation = "getConversationEmail"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}
