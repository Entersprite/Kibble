import ChatKit

public struct SearchConversationApps: ServiceRequestPayload {
    public typealias Response = [ConversationApp]
    public static let operation = "searchConversationApps"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let query: String

    public init(query: String, conversationID: Conversation.ID) {
        self.query = query; self.conversationID = conversationID
    }
}
