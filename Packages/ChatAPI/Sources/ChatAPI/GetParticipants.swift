import ChatKit
import Foundation

public struct GetParticipants: ServiceRequestPayload {
    public typealias Response = ConversationParticipantPage
    public static let operation = "getParticipants"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let cursor: String?

    public init(conversationID: Conversation.ID, cursor: String?) {
        self.conversationID = conversationID
        self.cursor = cursor
    }
}
