import ChatKit

/// A fresh provider observation, scoped to the original authenticated account.
public struct GetCallAvailability: ServiceRequestPayload {
    public typealias Response = ConversationCallAvailability
    public static let operation = "getCallAvailability"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}
