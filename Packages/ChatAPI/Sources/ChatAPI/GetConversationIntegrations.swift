import ChatKit
import Foundation

public struct GetConversationIntegrations: ServiceRequestPayload {
    public typealias Response = ConversationIntegrations
    public static let operation = "getConversationIntegrations"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID

    public init(conversationID: Conversation.ID) {
        self.conversationID = conversationID
    }
}

/// An ephemeral read. The response must not be retained in a mutation ledger or replica.
public struct GetWebhookDeliveryURL: ServiceRequestPayload {
    public typealias Response = URL
    public static let operation = "getWebhookDeliveryURL"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let webhookID: String

    public init(webhookID: String, conversationID: Conversation.ID) {
        self.webhookID = webhookID; self.conversationID = conversationID
    }
}
