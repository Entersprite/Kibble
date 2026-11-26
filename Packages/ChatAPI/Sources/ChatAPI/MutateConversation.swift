import ChatKit
import Foundation

public struct MutateConversation: ServiceRequestPayload {
    public typealias Response = ConversationMutationResult
    public static let operation = "mutateConversation"
    public static let requiresAccount = true
    public let mutation: ConversationMutation
    public let conversationID: Conversation.ID
    public let operationID: ServiceOperationID
    public let expectedRevision: String?

    public init(
        mutation: ConversationMutation,
        conversationID: Conversation.ID,
        operationID: ServiceOperationID,
        expectedRevision: String?
    ) {
        self.mutation = mutation
        self.conversationID = conversationID
        self.operationID = operationID
        self.expectedRevision = expectedRevision
    }
}
