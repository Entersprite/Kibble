import ChatKit

public struct OpenConversationApp: ServiceRequestPayload {
    public typealias Response = Conversation
    public static let operation = "openConversationApp"
    public static let requiresAccount = true
    public let conversationID: Conversation.ID
    public let appID: Member.ID
    public let operationID: ServiceOperationID

    public init(appID: Member.ID, conversationID: Conversation.ID, operationID: ServiceOperationID) {
        self.appID = appID; self.conversationID = conversationID; self.operationID = operationID
    }
}
